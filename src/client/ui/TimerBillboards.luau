local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))
local BillboardGuiTemplates = require(script.Parent:WaitForChild("BillboardGuiTemplates"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local TimerBillboards = {}

local TEMPLATE_NAME = "TimerBillboard"
local TITLE_LABEL_NAME = "TitleLabel"
local TIME_LABEL_NAME = "TimeLabel"
local UPDATE_SECONDS = 0.25
local TIMER_HEIGHT_ABOVE_PRIMARY_BOTTOM = 3

local player = Players.LocalPlayer
local tracked = {}
local trackedAncestryConns = {} -- [Instance] = RBXScriptConnection, paired with tracked
local candidateConnections = {}
local template = nil
local warnedTemplate = false
local warnedLabels = false
local plotDescendantAdded = nil
local scanRevision = 0

local function getTemplate()
	if template and template.Parent then
		return template
	end

	local found = BillboardGuiTemplates.Find(TEMPLATE_NAME)
	if not (found and found:IsA("BillboardGui")) then
		if not warnedTemplate then
			warn("[TimerBillboards] Missing " .. BillboardGuiTemplates.Path(TEMPLATE_NAME) .. " BillboardGui")
			warnedTemplate = true
		end
		return nil
	end

	template = found
	return template
end

local function label(root, name)
	local found = root:FindFirstChild(name, true)
	return found and found:IsA("TextLabel") and found or nil
end

local function firstBasePart(instance)
	if instance:IsA("BasePart") then
		return instance
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			return descendant
		end
	end
	return nil
end

local function adorneeFor(instance)
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or firstBasePart(instance)
	end
	return nil
end

local function isInOwnPlot(instance)
	local plot = PlotResolver.ResolveForPlayer(player)
	return plot ~= nil and instance:IsDescendantOf(plot)
end

local function feedMachineClass(instance)
	local feedClass = instance:GetAttribute(State.Feed.Class)
	if type(feedClass) == "string" and feedClass ~= "" then
		return feedClass
	end
	return nil
end

local function processingQueueEndAt(instance)
	local feedClass = feedMachineClass(instance)
	if feedClass ~= "Processor" and feedClass ~= "JamBarrel" then
		return nil
	end

	local queueCount = instance:GetAttribute(State.Feed.QueueCount)
	local readyCount = instance:GetAttribute(State.Feed.ReadyCount)
	local queueReadyAt = instance:GetAttribute(State.Feed.QueueReadyAt)
	if type(queueCount) ~= "number" or queueCount <= 0 then return nil end
	if type(readyCount) == "number" and readyCount >= queueCount then return nil end
	if type(queueReadyAt) ~= "number" or queueReadyAt <= os.time() then return nil end
	return queueReadyAt
end

local function timerContext(instance)
	if not (instance:IsA("BasePart") or instance:IsA("Model")) then
		return nil
	end

	if instance:GetAttribute(State.Seed.Phase) == "GrowingSeed" then
		local growEndAt = instance:GetAttribute(State.Seed.GrowEndAt)
		if type(growEndAt) == "number" then
			return tostring(instance:GetAttribute(State.Seed.TargetDisplayName) or "Growing"), growEndAt
		end
	end

	local queueReadyAt = processingQueueEndAt(instance)
	if queueReadyAt then
		return instance.Name, queueReadyAt
	end

	return nil
end

local function hasActiveTimer(instance)
	local title, endAt = timerContext(instance)
	return title ~= nil and type(endAt) == "number"
end

local function shouldWatchCandidate(instance)
	if not (instance:IsA("BasePart") or instance:IsA("Model")) then
		return false
	end
	if instance:GetAttribute(State.Feed.Index) ~= nil then
		return true
	end
	if instance:GetAttribute(State.Seed.Phase) ~= nil or instance:GetAttribute(State.Seed.GrowEndAt) ~= nil then
		return true
	end
	return instance:GetAttribute(State.Feed.QueueReadyAt) ~= nil
		or instance:GetAttribute(State.Feed.QueueCount) ~= nil
		or instance:GetAttribute(State.Feed.ReadyCount) ~= nil
end

local function formatRemaining(seconds)
	seconds = math.max(math.ceil(seconds), 0)
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	local remainder = seconds % 60
	if hours > 0 then
		return string.format("%02d:%02d:%02d", hours, minutes, remainder)
	end
	if minutes > 0 then
		return string.format("%02d:%02d", minutes, remainder)
	end
	return string.format("%ds", remainder)
end

-- The single drop path: the AncestryChanged connection must die with the
-- tracked entry, or machines accumulate one connection per timer cycle.
local function dropTracked(instance)
	local gui = tracked[instance]
	if gui then gui:Destroy() end
	tracked[instance] = nil
	local conn = trackedAncestryConns[instance]
	if conn then
		conn:Disconnect()
		trackedAncestryConns[instance] = nil
	end
end

local function update(instance, gui)
	if not isInOwnPlot(instance) then
		dropTracked(instance)
		return
	end

	local titleText, endAt = timerContext(instance)
	if not titleText then
		dropTracked(instance)
		return
	end

	local title = label(gui, TITLE_LABEL_NAME)
	local time = label(gui, TIME_LABEL_NAME)
	if not (title and time) then
		if not warnedLabels then
			warn("[TimerBillboards] TimerBillboard missing TitleLabel or TimeLabel")
			warnedLabels = true
		end
		dropTracked(instance)
		return
	end

	title.Text = titleText
	time.Text = formatRemaining(endAt - os.time())
end

local function attach(instance)
	if tracked[instance] or not hasActiveTimer(instance) or not isInOwnPlot(instance) then
		return
	end

	local baseTemplate = getTemplate()
	local adornee = adorneeFor(instance)
	if not (baseTemplate and adornee) then
		return
	end

	local gui = baseTemplate:Clone()
	UiEffects.BindBillboardPop(gui)
	gui.Adornee = adornee
	if instance:GetAttribute(State.Seed.Phase) == "GrowingSeed"
		and instance:GetAttribute(State.Feed.Class) == "Tree" then
		gui.StudsOffset = Vector3.zero
		gui.StudsOffsetWorldSpace = Vector3.new(0, -adornee.Size.Y * 0.5 + TIMER_HEIGHT_ABOVE_PRIMARY_BOTTOM, 0)
	end
	gui.Parent = adornee
	UiEffects.BindBillboardDistancePop(gui)
	tracked[instance] = gui
	trackedAncestryConns[instance] = RuntimeGuard.Connect(instance.AncestryChanged, "TimerBillboards.AncestryChanged", function()
		if not instance:IsDescendantOf(Workspace) then
			dropTracked(instance)
		end
	end)
	update(instance, gui)
end

local function refreshCandidate(instance)
	if hasActiveTimer(instance) then
		attach(instance)
	elseif tracked[instance] then
		update(instance, tracked[instance])
	end
end

local function clearCandidateWatch(instance)
	local conns = candidateConnections[instance]
	if not conns then return end
	for _, conn in ipairs(conns) do
		conn:Disconnect()
	end
	candidateConnections[instance] = nil
end

local function clearAllCandidateWatches()
	local instances = {}
	for instance in pairs(candidateConnections) do
		instances[#instances + 1] = instance
	end
	for _, instance in ipairs(instances) do
		clearCandidateWatch(instance)
	end
end

local function watchCandidate(instance)
	if candidateConnections[instance] then return end
	if not shouldWatchCandidate(instance) then return end
	if not isInOwnPlot(instance) then return end

	local conns = {}
	local function refresh()
		refreshCandidate(instance)
	end
	for _, attributeName in ipairs({
		State.Seed.Phase,
		State.Seed.GrowEndAt,
		State.Seed.TargetDisplayName,
		State.Feed.Class,
		State.Feed.QueueCount,
		State.Feed.ReadyCount,
		State.Feed.QueueReadyAt,
	}) do
		conns[#conns + 1] = RuntimeGuard.Connect(instance:GetAttributeChangedSignal(attributeName), "TimerBillboards.CandidateAttributeChanged", refresh)
	end
	conns[#conns + 1] = RuntimeGuard.Connect(instance.AncestryChanged, "TimerBillboards.CandidateAncestryChanged", function()
		if not instance:IsDescendantOf(Workspace) then
			clearCandidateWatch(instance)
		end
	end)
	candidateConnections[instance] = conns
	refresh()
end

local function scan()
	local plot = PlotResolver.ResolveForPlayer(player)
	if not plot then
		return
	end
	for _, instance in ipairs(plot:GetDescendants()) do
		watchCandidate(instance)
	end
end

local function watchCurrentPlot()
	scanRevision += 1
	local revision = scanRevision
	if plotDescendantAdded then
		plotDescendantAdded:Disconnect()
		plotDescendantAdded = nil
	end
	clearAllCandidateWatches()
	for instance in pairs(tracked) do
		dropTracked(instance)
	end

	local plot = PlotResolver.ResolveForPlayer(player)
	if not plot then
		return
	end
	plotDescendantAdded = RuntimeGuard.Connect(plot.DescendantAdded, "TimerBillboards.PlotDescendantAdded", function(instance)
		task.defer(function()
			RuntimeGuard.Run("TimerBillboards.AttachDeferred", function()
				watchCandidate(instance)
			end)
		end)
		task.delay(0.5, function()
			RuntimeGuard.Run("TimerBillboards.AttachDelayed", function()
				watchCandidate(instance)
			end)
		end)
	end)
	scan()
	task.delay(0.5, function()
		if revision ~= scanRevision then
			return
		end
		RuntimeGuard.Run("TimerBillboards.DelayedScan", scan)
	end)
end

function TimerBillboards.start()
	task.defer(function()
		RuntimeGuard.Run("TimerBillboards.WatchInitialPlot", watchCurrentPlot)
	end)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.AssignedPlotName), "TimerBillboards.AssignedPlotChanged", watchCurrentPlot)
	RuntimeGuard.Connect(Workspace.ChildAdded, "TimerBillboards.WorkspaceChildAdded", function(child)
		if child.Name == "Plots" and child:IsA("Folder") then
			task.defer(watchCurrentPlot)
		end
	end)
	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, function()
		task.defer(watchCurrentPlot)
	end)

	local elapsed = 0
	RuntimeGuard.Connect(RunService.Heartbeat, "TimerBillboards.Heartbeat", function(dt)
		elapsed += dt
		if elapsed < UPDATE_SECONDS then
			return
		end
		elapsed = 0
		for instance, gui in pairs(tracked) do
			RuntimeGuard.Run("TimerBillboards.Update", update, instance, gui)
		end
		for instance in pairs(candidateConnections) do
			if not tracked[instance] and hasActiveTimer(instance) then
				RuntimeGuard.Run("TimerBillboards.RetryAttach", refreshCandidate, instance)
			end
		end
	end)
end

return TimerBillboards
