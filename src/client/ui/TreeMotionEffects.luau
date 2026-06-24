local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local TreeMotionEffects = {}

local SHAKE_DURATION = 0.25
local SHAKE_ANGLE = math.rad(5)
local SHAKE_OFFSET = 0.12

local SWAY_ANGLE = math.rad(3)
local SWAY_OFFSET = 0.08
local SWAY_FREQUENCY = 1.4

local targetCache = {}
local activeEffects = {}
local renderConnection = nil

local function targetCFrame(target)
	if target:IsA("BasePart") then return target.CFrame end
	if target:IsA("Model") then return target:GetPivot() end
	return CFrame.identity
end

local function treePivotCFrame(tree)
	local primary = tree.PrimaryPart
	if primary and primary.Parent then
		return primary.CFrame
	end
	return tree:GetPivot()
end

local function setTargetBaseCFrame(treePivot, target, cframe)
	target.baseCFrame = cframe
	target.localBaseCFrame = treePivot:ToObjectSpace(cframe)
end

local function targetBaseCFrame(treePivot, target)
	if target.localBaseCFrame then
		return treePivot * target.localBaseCFrame
	end
	return target.baseCFrame
end

local function applyTargetCFrame(target, cframe)
	if target:IsA("BasePart") then
		target.CFrame = cframe
	elseif target:IsA("Model") then
		target:PivotTo(cframe)
	end
end

local function applyMotionTarget(target, cframe)
	applyTargetCFrame(target.instance, cframe)
	if not target.children then return end

	for _, child in ipairs(target.children) do
		if child.instance.Parent then
			child.instance.CFrame = cframe * child.localCFrame
		end
	end
end

local function restoreTargets(tree, targets)
	local treePivot = treePivotCFrame(tree)
	for _, target in ipairs(targets) do
		if target.instance.Parent then
			applyMotionTarget(target, targetBaseCFrame(treePivot, target))
		end
	end
end

local function hasLeafAncestor(part, tree)
	local parent = part.Parent
	while parent and parent ~= tree do
		if parent:IsA("BasePart") and parent.Name == "Leaf" then
			return true
		end
		parent = parent.Parent
	end
	return false
end

local function leafChildren(leaf)
	local children = {}
	for _, descendant in ipairs(leaf:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(children, {
				instance = descendant,
				localCFrame = leaf.CFrame:ToObjectSpace(descendant.CFrame),
			})
		end
	end
	return children
end

local function collectTargets(tree)
	local targets = {}
	local treePivot = treePivotCFrame(tree)
	for _, descendant in ipairs(tree:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name == "Leaf" and not hasLeafAncestor(descendant, tree) then
			local target = {
				instance = descendant,
				children = leafChildren(descendant),
				kind = "leaf",
				phase = math.random() * math.pi * 2,
			}
			setTargetBaseCFrame(treePivot, target, descendant.CFrame)
			table.insert(targets, target)
		end
	end
	for _, anchor in ipairs(tree:GetChildren()) do
		if anchor.Name == "SlotAnchor" then
			for _, child in ipairs(anchor:GetChildren()) do
				if child:IsA("BasePart") or child:IsA("Model") then
					local target = {
						instance = child,
						kind = "slot",
						phase = #targets * 0.7,
					}
					setTargetBaseCFrame(treePivot, target, targetCFrame(child))
					table.insert(targets, target)
				end
			end
		end
	end
	return targets
end

local function stopRenderConnectionIfIdle()
	if next(activeEffects) ~= nil then
		return
	end
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
end

local function clearTargetCache(tree)
	local cacheRecord = targetCache[tree]
	if not cacheRecord then return end
	for _, conn in ipairs(cacheRecord.conns) do
		conn:Disconnect()
	end
	local activeRecord = activeEffects[tree]
	if activeRecord then
		restoreTargets(tree, activeRecord.targets)
		activeEffects[tree] = nil
		stopRenderConnectionIfIdle()
	end
	targetCache[tree] = nil
end

local function cachedTargets(tree)
	local cacheRecord = targetCache[tree]
	if cacheRecord then
		if cacheRecord.dirty and not activeEffects[tree] then
			clearTargetCache(tree)
			cacheRecord = nil
		end
	end
	if cacheRecord then
		if not activeEffects[tree] then
			local treePivot = treePivotCFrame(tree)
			for _, target in ipairs(cacheRecord.targets) do
				if target.instance.Parent then
					setTargetBaseCFrame(treePivot, target, targetCFrame(target.instance))
				end
			end
		end
		return cacheRecord.targets
	end

	local targets = collectTargets(tree)
	local conns = {}
	local function invalidate()
		if activeEffects[tree] then
			local record = targetCache[tree]
			if record then
				record.dirty = true
			end
		else
			clearTargetCache(tree)
		end
	end
	table.insert(conns, tree.DescendantAdded:Connect(invalidate))
	table.insert(conns, tree.DescendantRemoving:Connect(invalidate))
	table.insert(conns, tree.AncestryChanged:Connect(function()
		if not tree:IsDescendantOf(Workspace) then
			invalidate()
		end
	end))
	targetCache[tree] = {
		targets = targets,
		conns = conns,
	}
	return targets
end

local function smoothEnvelope(alpha)
	alpha = math.clamp(alpha, 0, 1)
	local edge = math.min(alpha / 0.25, (1 - alpha) / 0.25, 1)
	return edge * edge * (3 - 2 * edge)
end

local function updateActiveRecord(tree, record, now)
	if not tree.Parent then
		clearTargetCache(tree)
		return
	end

	local shake = record.shake
	local sway = record.sway

	if shake and now - shake.startedAt >= shake.duration then
		record.shake = nil
		shake = nil
	end
	if sway and now - sway.startedAt >= sway.duration then
		record.sway = nil
		sway = nil
	end

	if not shake and not sway then
		restoreTargets(tree, record.targets)
		activeEffects[tree] = nil
		local cacheRecord = targetCache[tree]
		if cacheRecord and cacheRecord.dirty then
			clearTargetCache(tree)
		end
		return
	end

	local treePivot = treePivotCFrame(tree)
	for _, target in ipairs(record.targets) do
		if target.instance.Parent then
			local cframe = targetBaseCFrame(treePivot, target)
			if sway and target.kind == "leaf" then
				local elapsed = now - sway.startedAt
				local alpha = elapsed / sway.duration
				local envelope = smoothEnvelope(alpha)
				local wave = math.sin((elapsed * math.pi * 2 * SWAY_FREQUENCY) + target.phase) * envelope
				cframe = cframe
					* CFrame.new(wave * SWAY_OFFSET, 0, 0)
					* CFrame.Angles(0, 0, wave * SWAY_ANGLE)
			end
			if shake then
				local elapsed = now - shake.startedAt
				local alpha = elapsed / shake.duration
				local fade = 1 - math.clamp(alpha, 0, 1)
				local wave = math.sin((elapsed * 42) + target.phase) * fade
				cframe = cframe
					* CFrame.new(wave * SHAKE_OFFSET, 0, 0)
					* CFrame.Angles(0, 0, wave * SHAKE_ANGLE)
			end
			applyMotionTarget(target, cframe)
		end
	end
end

local function ensureRenderConnection()
	if renderConnection then
		return
	end
	renderConnection = RuntimeGuard.Connect(RunService.RenderStepped, "TreeMotionEffects.RenderStepped", function()
		local now = os.clock()
		for tree, record in pairs(activeEffects) do
			updateActiveRecord(tree, record, now)
		end
		stopRenderConnectionIfIdle()
	end)
end

local function ensureActiveRecord(tree)
	local record = activeEffects[tree]
	if record then
		return record
	end

	local targets = cachedTargets(tree)
	if #targets == 0 then
		return nil
	end

	record = {
		targets = targets,
		shake = nil,
		sway = nil,
	}
	activeEffects[tree] = record
	ensureRenderConnection()

	return record
end

function TreeMotionEffects.ShakeTree(tree)
	if not tree or not tree.Parent then return end

	local record = ensureActiveRecord(tree)
	if not record then return end
	record.shake = {
		startedAt = os.clock(),
		duration = SHAKE_DURATION,
	}
end

function TreeMotionEffects.SwayTree(tree, duration)
	if not tree or not tree.Parent then return end
	duration = tonumber(duration) or 0
	if duration <= 0 then return end

	local record = ensureActiveRecord(tree)
	if not record then return end
	record.sway = {
		startedAt = os.clock(),
		duration = duration,
	}
end

function TreeMotionEffects.ClearTree(tree)
	clearTargetCache(tree)
end

function TreeMotionEffects.ClearPlot(plot)
	for tree in pairs(targetCache) do
		if tree:IsDescendantOf(plot) then
			clearTargetCache(tree)
		end
	end
end

return TreeMotionEffects
