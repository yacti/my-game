-- Renders an xp badge above any equipped food Tool. Built per-viewer locally
-- under the Tool's Handle, so the billboard isn't replicated and can be
-- restyled or hidden without touching the server.
--
-- Server owns the XP data; this module only reads it and rebuilds the label
-- when it changes.
--
-- We watch Workspace descendants — a Tool only reaches Workspace when it's
-- equipped (parented to a Character), which is exactly when the badge
-- should be visible.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local State = require(ReplicatedStorage.Shared:WaitForChild("State"))

local ToolStatsBillboard = {}

local TOOL_STATS_TEMPLATE_NAME = "ToolStatsBillboard"
local STATS_LABEL_NAME = "StatsLabel"
local warnedMissingTemplate = false
local warnedMissingLabel = false

local function cloneTemplate()
	local uiFolder = ReplicatedStorage:FindFirstChild("UI")
	local template = uiFolder and uiFolder:FindFirstChild(TOOL_STATS_TEMPLATE_NAME)
	if not (template and template:IsA("BillboardGui")) then
		if not warnedMissingTemplate then
			warn("[ToolStatsBillboard] Missing ReplicatedStorage.UI.ToolStatsBillboard BillboardGui")
			warnedMissingTemplate = true
		end
		return nil
	end
	return template:Clone()
end

local function findStatsLabel(gui)
	local label = gui:FindFirstChild(STATS_LABEL_NAME, true)
	if label and label:IsA("TextLabel") then
		return label
	end
	if not warnedMissingLabel then
		warn("[ToolStatsBillboard] ToolStatsBillboard missing StatsLabel TextLabel")
		warnedMissingLabel = true
	end
	return nil
end

local function isFoodTool(obj)
	return obj:IsA("Tool")
		and (obj:GetAttribute(State.Food.Id) ~= nil or obj:GetAttribute(State.Food.Type) ~= nil)
end

local function build(tool)
	local handle = tool:FindFirstChild("Handle")
	if not handle then return end
	if handle:FindFirstChild("Stats") then return end

	local gui = cloneTemplate()
	if not gui then return end
	local label = findStatsLabel(gui)
	if not label then
		gui:Destroy()
		return
	end

	gui.Name = "Stats"
	gui.Adornee = handle
	gui.StudsOffset = Vector3.new(0, handle.Size.Y / 2 + 1, 0)

	local function render()
		local xp = tool:GetAttribute(State.Food.XP) or 0
		label.Text = string.format("%dxp", math.floor(xp))
	end
	render()
	tool:GetAttributeChangedSignal(State.Food.XP):Connect(render)

	gui.Parent = handle
end

function ToolStatsBillboard.start()
	for _, d in ipairs(Workspace:GetDescendants()) do
		if isFoodTool(d) then build(d) end
	end
	Workspace.DescendantAdded:Connect(function(d)
		if isFoodTool(d) then build(d) end
	end)
end

return ToolStatsBillboard
