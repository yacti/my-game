local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))
local BillboardGuiTemplates = require(script.Parent:WaitForChild("BillboardGuiTemplates"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local TimerBillboards = {}

local TEMPLATE_WAIT_SECONDS = 8
local TEMPLATE_NAME = "TimerBillboard"
local TITLE_LABEL_NAME = "TitleLabel"
local TIME_LABEL_NAME = "TimeLabel"
local UPDATE_SECONDS = 0.25
local SCAN_SECONDS = 1

local player = Players.LocalPlayer
local tracked = {}
local template = nil
local warnedTemplate = false
local warnedLabels = false
local plotDescendantAdded = nil

local function getTemplate()
	if template ~= nil then
		return template ~= false and template or nil
	end

	local found = BillboardGuiTemplates.WaitFor(TEMPLATE_NAME, TEMPLATE_WAIT_SECONDS)
	if not (found and found:IsA("BillboardGui")) then
		if not warnedTemplate then
			warn("[TimerBillboards] Missing " .. BillboardGuiTemplates.Path(TEMPLATE_NAME) .. " BillboardGui")
			warnedTemplate = true
		end
		template = false
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

local function formatRemaining(seconds)
	seconds = math.max(math.ceil(seconds), 0)
	local minutes = math.floor(seconds / 60)
	local remainder = seconds % 60
	if minutes > 0 then
		return string.format("%dm %02ds", minutes, remainder)
	end
	return string.format("%ds", remainder)
end

local function update(instance, gui)
	if not isInOwnPlot(instance) then
		if gui then gui:Destroy() end
		tracked[instance] = nil
		return
	end

	local titleText, endAt = timerContext(instance)
	if not titleText then
		if gui then gui:Destroy() end
		tracked[instance] = nil
		return
	end

	local title = label(gui, TITLE_LABEL_NAME)
	local time = label(gui, TIME_LABEL_NAME)
	if not (title and time) then
		if not warnedLabels then
			warn("[TimerBillboards] TimerBillboard missing TitleLabel or TimeLabel")
			warnedLabels = true
		end
		gui:Destroy()
		tracked[instance] = nil
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
	gui.Parent = adornee
	UiEffects.BindBillboardDistancePop(gui)
	tracked[instance] = gui
	update(instance, gui)

	RuntimeGuard.Connect(instance.AncestryChanged, "TimerBillboards.AncestryChanged", function()
		if not instance:IsDescendantOf(Workspace) then
			if tracked[instance] then tracked[instance]:Destroy() end
			tracked[instance] = nil
		end
	end)
end

local function scan()
	local plot = PlotResolver.ResolveForPlayer(player)
	if not plot then
		return
	end
	for _, instance in ipairs(plot:GetDescendants()) do
		if hasActiveTimer(instance) then
			attach(instance)
		end
	end
end

local function watchCurrentPlot()
	if plotDescendantAdded then
		plotDescendantAdded:Disconnect()
		plotDescendantAdded = nil
	end

	local plot = PlotResolver.ResolveForPlayer(player)
	if not plot then
		return
	end
	plotDescendantAdded = RuntimeGuard.Connect(plot.DescendantAdded, "TimerBillboards.PlotDescendantAdded", function(instance)
		task.defer(function()
			RuntimeGuard.Run("TimerBillboards.AttachDeferred", function()
				if hasActiveTimer(instance) then
					attach(instance)
				end
			end)
		end)
	end)
	scan()
end

function TimerBillboards.start()
	task.defer(function()
		RuntimeGuard.Run("TimerBillboards.WatchInitialPlot", watchCurrentPlot)
	end)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.AssignedPlotName), "TimerBillboards.AssignedPlotChanged", watchCurrentPlot)

	local elapsed = 0
	local scanElapsed = 0
	RuntimeGuard.Connect(RunService.Heartbeat, "TimerBillboards.Heartbeat", function(dt)
		elapsed += dt
		scanElapsed += dt
		if scanElapsed >= SCAN_SECONDS then
			scanElapsed = 0
			RuntimeGuard.Run("TimerBillboards.Scan", scan)
		end
		if elapsed < UPDATE_SECONDS then
			return
		end
		elapsed = 0
		for instance, gui in pairs(tracked) do
			RuntimeGuard.Run("TimerBillboards.Update", update, instance, gui)
		end
	end)
end

return TimerBillboards
