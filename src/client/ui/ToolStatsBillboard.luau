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

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local State = require(Shared:WaitForChild("State"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))
local XPBillboardTemplate = require(script.Parent:WaitForChild("XPBillboardTemplate"))

local ToolStatsBillboard = {}

local function isFoodTool(obj)
	return obj:IsA("Tool")
		and (obj:GetAttribute(State.Food.Id) ~= nil or obj:GetAttribute(State.Food.Type) ~= nil)
end

local function build(tool)
	local handle = tool:FindFirstChild("Handle")
	if not handle then return end
	if handle:FindFirstChild("Stats") then return end

	local gui, label = XPBillboardTemplate.Clone("ToolStatsBillboard")
	if not gui then return end

	gui.Name = "Stats"
	gui.Adornee = handle
	gui.StudsOffset = Vector3.new(0, handle.Size.Y / 2 + 1, 0)

	local function render()
		local xp = tool:GetAttribute(State.Food.XP) or 0
		label.Text = NumberFormatter.XP(xp, "xp")
	end
	render()
	tool:GetAttributeChangedSignal(State.Food.XP):Connect(render)

	gui.Parent = handle
	UiEffects.BindBillboardDistancePop(gui)
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
