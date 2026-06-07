-- Renders an XP billboard above each growing slot food. Visible while the
-- player's HumanoidRootPart is within RANGE studs of the food. Range is gated
-- against the player (not the camera) per Heartbeat — BillboardGui.MaxDistance
-- is camera-based and would hide legitimate slots when the camera is pulled
-- back.
--
-- Identification: patch slot food is any BasePart/Model with a FoodType
-- attribute that lives under a Patch machine's SlotAnchor. Tree machines also
-- use SlotAnchor for on-branch fruit, but those visuals should not get this UI.
-- Server keeps the XP attribute in sync. Distant billboards mark their label
-- stale and render only when they become visible again.
--
-- Per-viewer rendered locally; no replication of GUI instances.

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))
local XPBillboardTemplate = require(script.Parent:WaitForChild("XPBillboardTemplate"))

local RANGE = 10

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local tracked   = {}  -- [food] = { gui, label, conns, dirty, visible }

local SlotXPBillboard = {}

local function isSlotFood(obj)
	if not (obj:IsA("BasePart") or obj:IsA("Model")) then return false end
	if obj:GetAttribute(State.Food.Id) == nil and obj:GetAttribute(State.Food.Type) == nil then return false end
	local anchor = obj.Parent
	if not anchor or anchor.Name ~= "SlotAnchor" then return false end
	local machine = anchor.Parent
	return machine ~= nil and machine:GetAttribute(State.Feed.Class) == "Patch"
end

local function adorneeFor(food)
	if food:IsA("BasePart") then return food end
	if food:IsA("Model") then return food.PrimaryPart end
	return nil
end

local function foodPosition(food)
	if food:IsA("BasePart") then return food.Position end
	if food:IsA("Model") then return food:GetPivot().Position end
	return Vector3.zero
end

local function foodHeight(food)
	if food:IsA("BasePart") then return food.Size.Y end
	if food:IsA("Model") then return food:GetExtentsSize().Y end
	return 1
end

local function cleanup(food)
	local record = tracked[food]
	if not record then return end
	for _, conn in ipairs(record.conns) do
		conn:Disconnect()
	end
	if record.gui then
		record.gui:Destroy()
	end
	tracked[food] = nil
end

local function addConnection(record, conn)
	if conn then
		table.insert(record.conns, conn)
	end
end

local function build(food)
	if tracked[food] then return end
	local adornee = adorneeFor(food)
	if not adornee then return end

	local gui, label = XPBillboardTemplate.Clone("SlotXPBillboard")
	if not gui then return end

	gui.Name = "XPBillboard"
	gui.Adornee = adornee
	gui.Enabled = false  -- gated by Heartbeat below

	local record = {
		gui = gui,
		label = label,
		conns = {},
		dirty = true,
		visible = false,
	}

	local function render()
		local xp = food:GetAttribute(State.Food.XP) or 0
		label.Text = string.format("%dxp", math.floor(xp))
		record.dirty = false
	end
	addConnection(record, RuntimeGuard.Connect(food:GetAttributeChangedSignal(State.Food.XP), "SlotXPBillboard.MarkDirty", function()
		record.dirty = true
		if record.visible then
			render()
		end
	end))

	gui.Parent = playerGui
	tracked[food] = record

	addConnection(record, RuntimeGuard.Connect(gui.AncestryChanged, "SlotXPBillboard.GuiAncestryChanged", function()
		if not gui:IsDescendantOf(playerGui) then cleanup(food) end
	end))
	addConnection(record, RuntimeGuard.Connect(food.AncestryChanged, "SlotXPBillboard.AncestryChanged", function()
		if not food:IsDescendantOf(Workspace) then cleanup(food) end
	end))
end

function SlotXPBillboard.start()
	for _, d in ipairs(Workspace:GetDescendants()) do
		if isSlotFood(d) then RuntimeGuard.Run("SlotXPBillboard.BuildInitial", build, d) end
	end
	RuntimeGuard.Connect(Workspace.DescendantAdded, "SlotXPBillboard.DescendantAdded", function(d)
		if isSlotFood(d) then RuntimeGuard.Run("SlotXPBillboard.Build", build, d) end
	end)

	RuntimeGuard.Connect(RunService.Heartbeat, "SlotXPBillboard.Heartbeat", function()
		local char = player.Character
		local hrp  = char and char:FindFirstChild("HumanoidRootPart")
		for food, record in pairs(tracked) do
			RuntimeGuard.Run("SlotXPBillboard.UpdateVisibility", function()
				if hrp and food:IsDescendantOf(Workspace) then
					record.visible = (foodPosition(food) - hrp.Position).Magnitude <= RANGE
					record.gui.Enabled = record.visible
					if record.visible and record.dirty then
						local xp = food:GetAttribute(State.Food.XP) or 0
						record.label.Text = string.format("%dxp", math.floor(xp))
						record.dirty = false
					end
				else
					cleanup(food)
				end
			end)
		end
	end)
end

return SlotXPBillboard
