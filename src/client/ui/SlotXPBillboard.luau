-- Renders an XP billboard above each growing slot food. Visible while the
-- player's HumanoidRootPart is within RANGE studs of the food. Range is gated
-- against the player (not the camera) per Heartbeat — BillboardGui.MaxDistance
-- is camera-based and would hide legitimate slots when the camera is pulled
-- back.
--
-- Identification: patch slot food is any BasePart/Model with a FoodType
-- attribute that lives under a Patch machine's SlotAnchor. Tree machines also
-- use SlotAnchor for on-branch fruit, but those visuals should not get this UI.
-- Server keeps the XP attribute in sync, so the billboard just listens to
-- attribute changes.
--
-- Per-viewer rendered locally; no replication of GUI instances.

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local RANGE = 10
local SLOT_XP_TEMPLATE_NAME = "SlotXPBillboard"
local XP_LABEL_NAME = "XPLabel"

local player    = Players.LocalPlayer
local tracked   = {}  -- [food] = gui

local SlotXPBillboard = {}
local warnedMissingTemplate = false
local warnedMissingLabel = false

local function cloneTemplate()
	local uiFolder = ReplicatedStorage:FindFirstChild("UI")
	local template = uiFolder and uiFolder:FindFirstChild(SLOT_XP_TEMPLATE_NAME)
	if not (template and template:IsA("BillboardGui")) then
		if not warnedMissingTemplate then
			warn("[SlotXPBillboard] Missing ReplicatedStorage.UI.SlotXPBillboard BillboardGui")
			warnedMissingTemplate = true
		end
		return nil
	end
	return template:Clone()
end

local function findXPLabel(gui)
	local label = gui:FindFirstChild(XP_LABEL_NAME, true)
	if label and label:IsA("TextLabel") then
		return label
	end
	if not warnedMissingLabel then
		warn("[SlotXPBillboard] SlotXPBillboard missing XPLabel TextLabel")
		warnedMissingLabel = true
	end
	return nil
end

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

local function build(food)
	if tracked[food] then return end
	local adornee = adorneeFor(food)
	if not adornee then return end

	local gui = cloneTemplate()
	if not gui then return end
	local label = findXPLabel(gui)
	if not label then
		gui:Destroy()
		return
	end

	gui.Name = "XPBillboard"
	gui.Adornee = adornee
	gui.Enabled = false  -- gated by Heartbeat below

	local function render()
		local xp = food:GetAttribute(State.Food.XP) or 0
		label.Text = string.format("%dxp", math.floor(xp))
	end
	render()
	RuntimeGuard.Connect(food:GetAttributeChangedSignal(State.Food.XP), "SlotXPBillboard.Render", render)

	gui.Parent = food
	tracked[food] = gui

	RuntimeGuard.Connect(food.AncestryChanged, "SlotXPBillboard.AncestryChanged", function()
		if not food:IsDescendantOf(Workspace) then tracked[food] = nil end
	end)
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
		for food, gui in pairs(tracked) do
			RuntimeGuard.Run("SlotXPBillboard.UpdateVisibility", function()
				if hrp and food:IsDescendantOf(Workspace) then
					gui.Enabled = (foodPosition(food) - hrp.Position).Magnitude <= RANGE
				else
					gui.Enabled = false
				end
			end)
		end
	end)
end

return SlotXPBillboard
