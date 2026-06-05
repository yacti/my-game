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

local GrowingSeedBillboards = {}

local TEMPLATE_WAIT_SECONDS = 8
local TEMPLATE_NAME = "GrowingSeedBillboard"
local TITLE_LABEL_NAME = "TitleLabel"
local TIME_LABEL_NAME = "TimeLabel"
local UPDATE_SECONDS = 0.25

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
			warn("[GrowingSeedBillboards] Missing " .. BillboardGuiTemplates.Path(TEMPLATE_NAME) .. " BillboardGui")
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

local function isGrowing(instance)
	return (instance:IsA("BasePart") or instance:IsA("Model"))
		and instance:GetAttribute(State.Seed.Phase) == "GrowingSeed"
		and type(instance:GetAttribute(State.Seed.GrowEndAt)) == "number"
end

local function isInOwnPlot(instance)
	local plot = PlotResolver.ResolveForPlayer(player)
	return plot ~= nil and instance:IsDescendantOf(plot)
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
	if not isGrowing(instance) or not isInOwnPlot(instance) then
		if gui then gui:Destroy() end
		tracked[instance] = nil
		return
	end

	local title = label(gui, TITLE_LABEL_NAME)
	local time = label(gui, TIME_LABEL_NAME)
	if not (title and time) then
		if not warnedLabels then
			warn("[GrowingSeedBillboards] GrowingSeedBillboard missing TitleLabel or TimeLabel")
			warnedLabels = true
		end
		gui:Destroy()
		tracked[instance] = nil
		return
	end

	title.Text = tostring(instance:GetAttribute(State.Seed.TargetDisplayName) or "Growing")
	time.Text = formatRemaining((instance:GetAttribute(State.Seed.GrowEndAt) or os.time()) - os.time())
end

local function attach(instance)
	if tracked[instance] or not isGrowing(instance) or not isInOwnPlot(instance) then
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
	tracked[instance] = gui
	update(instance, gui)

	RuntimeGuard.Connect(instance.AncestryChanged, "GrowingSeedBillboards.AncestryChanged", function()
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
		if isGrowing(instance) then
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
	plotDescendantAdded = RuntimeGuard.Connect(plot.DescendantAdded, "GrowingSeedBillboards.PlotDescendantAdded", function(instance)
		task.defer(function()
			RuntimeGuard.Run("GrowingSeedBillboards.AttachDeferred", function()
				if isGrowing(instance) then
					attach(instance)
				end
			end)
		end)
	end)
	scan()
end

function GrowingSeedBillboards.start()
	task.defer(function()
		RuntimeGuard.Run("GrowingSeedBillboards.WatchInitialPlot", watchCurrentPlot)
	end)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.AssignedPlotName), "GrowingSeedBillboards.AssignedPlotChanged", watchCurrentPlot)

	local elapsed = 0
	RuntimeGuard.Connect(RunService.Heartbeat, "GrowingSeedBillboards.Heartbeat", function(dt)
		elapsed += dt
		if elapsed < UPDATE_SECONDS then
			return
		end
		elapsed = 0
		for instance, gui in pairs(tracked) do
			RuntimeGuard.Run("GrowingSeedBillboards.Update", update, instance, gui)
		end
	end)
end

return GrowingSeedBillboards
