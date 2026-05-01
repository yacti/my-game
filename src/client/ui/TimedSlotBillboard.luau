-- Renders an XP billboard above each growing food in a Timed machine
-- slot. Visible while the player's HumanoidRootPart is within RANGE studs
-- of the food. Range is gated against the player (not the camera) per
-- Heartbeat — BillboardGui.MaxDistance is camera-based and would hide
-- legitimate slots when the camera is pulled back.
--
-- Identification: a "slot food" is any BasePart/Model with a FoodType
-- attribute that either (a) lives under a parent named "SlotAnchor" — patch
-- growth slots — or (b) carries a TrackedFood=true attribute,
-- which other systems (e.g. AppleTree's ground fruit) opt into. Server
-- keeps the XP attribute in sync, so the billboard just listens to
-- attribute changes.
--
-- Per-viewer rendered locally; no replication of GUI instances.

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
local State = require(Shared:WaitForChild("State"))

local RANGE = 10

local player    = Players.LocalPlayer
local tracked   = {}  -- [food] = gui

local TimedSlotBillboard = {}

local function isSlotFood(obj)
	if not (obj:IsA("BasePart") or obj:IsA("Model")) then return false end
	if obj:GetAttribute(State.Food.Id) == nil and obj:GetAttribute(State.Food.Type) == nil then return false end
	if obj:GetAttribute("TrackedFood") == true then return true end
	return obj.Parent ~= nil and obj.Parent.Name == "SlotAnchor"
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

local function foodIdFor(food)
	local foodId = food:GetAttribute(State.Food.Id)
	if type(foodId) == "string" and foodId ~= "" then return foodId end
	local oldFoodType = food:GetAttribute(State.Food.Type)
	if type(oldFoodType) == "string" and Food.GetTemplate(oldFoodType) then return oldFoodType end
	return nil
end

local function maxXPFor(foodId)
	local t = foodId and Food.GetTemplate(foodId)
	return t and (t:GetAttribute("MaxXP") or 5) or 5
end

local function build(food)
	if tracked[food] then return end
	local adornee = adorneeFor(food)
	if not adornee then return end

	local gui = Instance.new("BillboardGui")
	gui.Name        = "XPBillboard"
	gui.Adornee     = adornee
	gui.Size        = UDim2.new(0, 80, 0, 24)
	-- Fixed offset that clears the food at max scale (1.5×) without
	-- needing to update each frame as the model grows.
	gui.StudsOffset = Vector3.new(0, 4, 0)
	gui.AlwaysOnTop = true
	gui.Enabled     = false  -- gated by Heartbeat below

	local label = Instance.new("TextLabel")
	label.Size                   = UDim2.fromScale(1, 1)
	label.BackgroundColor3       = Color3.fromRGB(30, 30, 30)
	label.BackgroundTransparency = 0.2
	label.TextColor3             = Color3.fromRGB(255, 255, 255)
	label.Font                   = Enum.Font.GothamBold
	label.TextScaled             = true
	label.Parent                 = gui
	Instance.new("UICorner", label).CornerRadius = UDim.new(0, 6)

	local function render()
		local xp       = food:GetAttribute("XP") or 0
		local maxXP    = maxXPFor(foodIdFor(food))
		label.Text = string.format("%d/%d xp", xp, maxXP)
	end
	render()
	food:GetAttributeChangedSignal("XP"):Connect(render)
	food:GetAttributeChangedSignal("FoodType"):Connect(render)
	food:GetAttributeChangedSignal(State.Food.Id):Connect(render)

	gui.Parent = food
	tracked[food] = gui

	food.AncestryChanged:Connect(function()
		if not food:IsDescendantOf(Workspace) then tracked[food] = nil end
	end)
end

function TimedSlotBillboard.start()
	for _, d in ipairs(Workspace:GetDescendants()) do
		if isSlotFood(d) then build(d) end
	end
	Workspace.DescendantAdded:Connect(function(d)
		if isSlotFood(d) then build(d) end
	end)

	RunService.Heartbeat:Connect(function()
		local char = player.Character
		local hrp  = char and char:FindFirstChild("HumanoidRootPart")
		for food, gui in pairs(tracked) do
			if hrp and food:IsDescendantOf(Workspace) then
				gui.Enabled = (foodPosition(food) - hrp.Position).Magnitude <= RANGE
			else
				gui.Enabled = false
			end
		end
	end)
end

return TimedSlotBillboard
