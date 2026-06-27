local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
local Mutations = require(Shared:WaitForChild("Mutations"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local AppleTreeSlotVisuals = require(script.Parent:WaitForChild("AppleTreeSlotVisuals"))
local PlotScope = require(script.Parent:WaitForChild("PlotScope"))

local MutationVisuals = {}

local FOLDER_NAME = "__MutationVisuals"
local MAX_VISUAL_DISTANCE = 80
local SCOPE_RANGE = MAX_VISUAL_DISTANCE
local REFRESH_SECONDS = 0.3
local DEFAULT_EFFECT_REFERENCE_EXTENT = 4
local MIN_EFFECT_SCALE = 0.2
local MAX_EFFECT_SCALE = 1.5
local EFFECT_EXTENT_EPSILON = 0.01

local player = Players.LocalPlayer
local tracked = {}

local function isTreeGroundCandidate(instance)
	return (instance:IsA("BasePart") or instance:IsA("Model"))
		and instance.Name:match("^BaseFoodGround%d+$") ~= nil
		and instance:GetAttribute(State.TreeClicker.LocalVisual) ~= true
end

local function isFoodCandidate(instance)
	if instance:IsA("Tool") then
		return instance:GetAttribute(State.Food.Id) ~= nil
			or instance:GetAttribute(State.Food.MutationIds) ~= nil
	end
	return isTreeGroundCandidate(instance) or ((instance:IsA("BasePart") or instance:IsA("Model"))
		and (
			instance:GetAttribute(State.Food.Id) ~= nil
			or instance:GetAttribute(State.Food.MutationIds) ~= nil
			or instance:GetAttribute(State.TreeClicker.GroundPile) == true
		)
		and instance:GetAttribute(State.TreeClicker.LocalVisual) ~= true)
end

local function firstBasePart(instance)
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	if instance:IsA("Tool") then
		return instance:FindFirstChild("Handle") or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function hostFor(target)
	if target:IsA("Tool") then
		return firstBasePart(target) or target
	end
	if target:GetAttribute(State.TreeClicker.GroundPile) == true then
		return AppleTreeSlotVisuals.GroundVisualForMarker(target) or target
	end
	return target
end

local function visualFolder(record, host)
	if record.folder and record.folder.Parent == host then
		return record.folder
	end
	if record.folder then
		record.folder:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = host
	record.folder = folder
	return folder
end

local function clearRecord(record)
	if record.folder then
		record.folder:Destroy()
		record.folder = nil
	end
	for _, instance in ipairs(record.extras or {}) do
		if instance.Parent then
			instance:Destroy()
		end
	end
	record.extras = {}
	record.scaledEmitters = {}
	record.effectExtent = nil
	record.renderKey = nil
	record.host = nil
end

local function playerPosition()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root.Position or nil
end

local function inVisualRange(targetPart)
	local position = playerPosition()
	if not position then
		return false
	end
	return (targetPart.Position - position).Magnitude <= MAX_VISUAL_DISTANCE
end

local function scaledNumberSequence(sequence, scale)
	local keypoints = table.create(#sequence.Keypoints)
	for index, keypoint in ipairs(sequence.Keypoints) do
		keypoints[index] = NumberSequenceKeypoint.new(
			keypoint.Time,
			keypoint.Value * scale,
			keypoint.Envelope * scale
		)
	end
	return NumberSequence.new(keypoints)
end

local function finitePositiveNumber(value)
	return type(value) == "number" and value == value and value > 0 and value < math.huge
end

local function instanceScale(instance)
	local ok, scale = pcall(function()
		return instance:GetScale()
	end)
	return ok and finitePositiveNumber(scale) and scale or nil
end

local function maxDimension(size)
	return math.max(size.X, size.Y, size.Z)
end

local function visualExtent(instance)
	if not instance then
		return nil
	end

	if instance:IsA("BasePart") then
		local extent = maxDimension(instance.Size)
		return finitePositiveNumber(extent) and extent or nil
	end

	if instance:IsA("Model") then
		local ok, _, size = pcall(function()
			return instance:GetBoundingBox()
		end)
		if ok and typeof(size) == "Vector3" then
			local extent = maxDimension(size)
			return finitePositiveNumber(extent) and extent or nil
		end
	end

	if instance:IsA("Tool") then
		local ok, _, size = pcall(function()
			return instance:GetBoundingBox()
		end)
		if ok and typeof(size) == "Vector3" then
			local extent = maxDimension(size)
			if finitePositiveNumber(extent) then
				return extent
			end
		end

		local part = firstBasePart(instance)
		if part then
			return visualExtent(part)
		end
	end

	return nil
end

local function persistedToolExtent(tool)
	if not (tool and tool:IsA("Tool")) then
		return nil
	end

	local scale = instanceScale(tool)
	if not scale then
		return nil
	end

	local foodId = Food.IdOf(tool)
	local template = foodId and Food.GetTemplate(foodId)
	local baseExtent = visualExtent(template)
	if not baseExtent then
		return nil
	end

	return baseExtent * scale
end

local function targetEffectExtent(target, host)
	if target:IsA("Tool") then
		return persistedToolExtent(target) or visualExtent(target) or visualExtent(host) or DEFAULT_EFFECT_REFERENCE_EXTENT
	end

	return visualExtent(host) or visualExtent(target) or DEFAULT_EFFECT_REFERENCE_EXTENT
end

local function templateReferenceExtent(template)
	return visualExtent(template) or DEFAULT_EFFECT_REFERENCE_EXTENT
end

local function registerScalableEmitters(record, root, referenceExtent)
	referenceExtent = finitePositiveNumber(referenceExtent) and referenceExtent or DEFAULT_EFFECT_REFERENCE_EXTENT
	if root:IsA("ParticleEmitter") then
		record.scaledEmitters[#record.scaledEmitters + 1] = {
			emitter = root,
			size = root.Size,
			referenceExtent = referenceExtent,
		}
	end

	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			record.scaledEmitters[#record.scaledEmitters + 1] = {
				emitter = descendant,
				size = descendant.Size,
				referenceExtent = referenceExtent,
			}
		end
	end
end

local function applyEffectScale(record)
	if #record.scaledEmitters == 0 then
		record.effectExtent = nil
		return
	end

	local extent = targetEffectExtent(record.target, record.host)
	if record.effectExtent and math.abs(record.effectExtent - extent) < EFFECT_EXTENT_EPSILON then
		return
	end

	for index = #record.scaledEmitters, 1, -1 do
		local entry = record.scaledEmitters[index]
		local emitter = entry.emitter
		if emitter and emitter.Parent then
			local referenceExtent = finitePositiveNumber(entry.referenceExtent)
				and entry.referenceExtent
				or DEFAULT_EFFECT_REFERENCE_EXTENT
			local scale = math.clamp(extent / referenceExtent, MIN_EFFECT_SCALE, MAX_EFFECT_SCALE)
			emitter.Size = scaledNumberSequence(entry.size, scale)
		else
			table.remove(record.scaledEmitters, index)
		end
	end
	record.effectExtent = extent
end

local function enablePersistentParticles(root)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = true
		end
	end
end

local function cloneVisualDescendant(descendant, host, folder, targetPart)
	if descendant:IsA("Highlight") then
		local highlight = descendant:Clone()
		highlight.Adornee = host
		highlight.Parent = folder
		return highlight
	end
	if descendant:IsA("Attachment") and targetPart then
		local attachment = descendant:Clone()
		attachment.Parent = targetPart
		return attachment
	end
	if descendant:IsA("ParticleEmitter") and targetPart and not descendant.Parent:IsA("Attachment") then
		local attachment = Instance.new("Attachment")
		attachment.Name = descendant.Name .. "Attachment"
		attachment.Parent = targetPart
		descendant:Clone().Parent = attachment
		return attachment
	end
	return nil
end

local function render(record)
	local target = record.target
	if not target then
		return false
	end

	local mutationIds = Mutations.FromInstance(target)
	local host = hostFor(target)
	local targetPart = firstBasePart(host)
	local key = table.concat(mutationIds, ",") .. "|" .. tostring(host)
	if not target:IsDescendantOf(Workspace) then
		clearRecord(record)
		record.renderKey = "not-in-world|" .. tostring(host)
		record.host = host
		return target.Parent ~= nil
	end
	if #mutationIds == 0 or not targetPart then
		clearRecord(record)
		record.renderKey = key
		record.host = host
		return true
	end
	if not inVisualRange(targetPart) then
		clearRecord(record)
		record.renderKey = "out-of-range|" .. tostring(host)
		record.host = host
		return true
	end
	if record.renderKey == key and record.host == host then
		applyEffectScale(record)
		return true
	end

	clearRecord(record)

	local folder = visualFolder(record, host)
	for _, mutationId in ipairs(mutationIds) do
		local template = Mutations.Template(mutationId)
		if template then
			local referenceExtent = templateReferenceExtent(template)
			for _, descendant in ipairs(template:GetDescendants()) do
				local clone = cloneVisualDescendant(descendant, host, folder, targetPart)
				if clone then
					clone.Name = mutationId .. "_" .. clone.Name
					if not clone:IsA("Highlight") then
						record.extras[#record.extras + 1] = clone
					end
					registerScalableEmitters(record, clone, referenceExtent)
					enablePersistentParticles(clone)
				end
			end
		end
	end
	record.renderKey = key
	record.host = host
	applyEffectScale(record)
	return true
end

local function cleanup(target)
	local record = tracked[target]
	if not record then
		return
	end
	for _, conn in ipairs(record.connections) do
		conn:Disconnect()
	end
	clearRecord(record)
	tracked[target] = nil
end

local function track(target)
	if tracked[target] or not isFoodCandidate(target) then
		return
	end
	local record = {
		target = target,
		connections = {},
		extras = {},
		scaledEmitters = {},
		effectExtent = nil,
		folder = nil,
		renderKey = nil,
		host = nil,
	}
	tracked[target] = record
	table.insert(record.connections, RuntimeGuard.Connect(target:GetAttributeChangedSignal(State.Food.MutationIds), "MutationVisuals.MutationChanged", function()
		render(record)
	end))
	table.insert(record.connections, RuntimeGuard.Connect(target.AncestryChanged, "MutationVisuals.AncestryChanged", function()
		if target.Parent == nil then
			cleanup(target)
		else
			render(record)
		end
	end))
	render(record)
end

local function scanRoot(root)
	for _, descendant in ipairs(root:GetDescendants()) do
		if isFoodCandidate(descendant) then
			track(descendant)
		end
	end
end

local function watchContainer(container, label)
	if not container then
		return nil
	end
	scanRoot(container)
	return RuntimeGuard.Connect(container.DescendantAdded, label .. ".DescendantAdded", function(descendant)
		if isFoodCandidate(descendant) then
			track(descendant)
		end
	end)
end

function MutationVisuals.start()
	PlotScope.Bind({
		label = "MutationVisuals",
		nearbyRange = SCOPE_RANGE,
		onPlotAdded = function(plot)
			scanRoot(plot)
			local conn = RuntimeGuard.Connect(plot.DescendantAdded, "MutationVisuals.DescendantAdded", function(descendant)
				if isFoodCandidate(descendant) then
					track(descendant)
				end
			end)
			return function()
				if conn then
					conn:Disconnect()
				end
				for target in pairs(tracked) do
					if target:IsDescendantOf(plot) then
						cleanup(target)
					end
				end
			end
		end,
	})

	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		watchContainer(backpack, "MutationVisuals.Backpack")
	end

	local characterConnection = nil
	local function bindCharacter(character)
		if characterConnection then
			characterConnection:Disconnect()
			characterConnection = nil
		end
		characterConnection = watchContainer(character, "MutationVisuals.Character")
	end
	if player.Character then
		bindCharacter(player.Character)
	end
	RuntimeGuard.Connect(player.CharacterAdded, "MutationVisuals.CharacterAdded", bindCharacter)

	local elapsed = 0
	RuntimeGuard.Connect(RunService.Heartbeat, "MutationVisuals.Refresh", function(dt)
		elapsed += dt
		if elapsed < REFRESH_SECONDS then
			return
		end
		elapsed = 0
		for target, record in pairs(tracked) do
			if not render(record) then
				cleanup(target)
			end
		end
	end)
end

return MutationVisuals
