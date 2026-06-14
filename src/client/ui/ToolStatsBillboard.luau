-- Renders an xp badge above any equipped food Tool. Built per-viewer locally
-- under the Tool's Handle, so the billboard isn't replicated and can be
-- restyled or hidden without touching the server.
--
-- Server owns the XP data; this module only reads it and rebuilds the label
-- when it changes.
--
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local State = require(Shared:WaitForChild("State"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))
local XPBillboardTemplate = require(script.Parent:WaitForChild("XPBillboardTemplate"))

local ToolStatsBillboard = {}
local player = Players.LocalPlayer
local trackedTools = setmetatable({}, { __mode = "k" })

local function isFoodTool(obj)
	return obj:IsA("Tool")
		and (obj:GetAttribute(State.Food.Id) ~= nil or obj:GetAttribute(State.Food.Type) ~= nil)
end

local function cleanup(tool, destroyGui)
	local record = trackedTools[tool]
	if not record then
		return
	end
	trackedTools[tool] = nil
	for _, connection in ipairs(record.connections) do
		connection:Disconnect()
	end
	if destroyGui ~= false and record.gui and record.gui.Parent then
		record.gui:Destroy()
	end
end

local function build(tool)
	if tool.Parent ~= player.Character then return end
	local existing = trackedTools[tool]
	if existing and existing.gui and existing.gui.Parent then
		return
	elseif existing then
		cleanup(tool, true)
	end

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
		label.Text = NumberFormatter.XP(xp, " XP")
	end
	render()

	local record = {
		gui = gui,
		connections = {},
	}
	trackedTools[tool] = record
	record.connections[#record.connections + 1] = tool:GetAttributeChangedSignal(State.Food.XP):Connect(render)
	record.connections[#record.connections + 1] = tool.Destroying:Connect(function()
		cleanup(tool, true)
	end)
	record.connections[#record.connections + 1] = tool.AncestryChanged:Connect(function()
		if tool.Parent ~= player.Character then
			cleanup(tool, true)
		end
	end)
	record.connections[#record.connections + 1] = gui.Destroying:Connect(function()
		cleanup(tool, false)
	end)

	gui.Parent = handle
	UiEffects.BindBillboardDistancePop(gui)
end

function ToolStatsBillboard.start()
	local function watchCharacter(character)
		if not character then return end
		for _, child in ipairs(character:GetChildren()) do
			if isFoodTool(child) then build(child) end
		end
		character.ChildAdded:Connect(function(child)
			if isFoodTool(child) then build(child) end
		end)
		character.ChildRemoved:Connect(function(child)
			if isFoodTool(child) then cleanup(child, true) end
		end)
	end
	player.CharacterAdded:Connect(watchCharacter)
	watchCharacter(player.Character)
end

return ToolStatsBillboard
