-- Client-only scale presentation for mature patch slot fruit.
-- Server owns XP and harvest state; this module decides which nearby fruit
-- should spend local work applying the latest visual scale.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PatchScale = require(Shared:WaitForChild("PatchScale"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local PatchSlotVisuals = {}

local VISUAL_RANGE = 70
local RANGE_CHECK_INTERVAL = 0.2
local MAX_SCALE_UPDATES_PER_STEP = 80

local player = Players.LocalPlayer
local tracked = {} -- [foodModel] = record

local function isPatchSlotFood(obj)
	if not (obj:IsA("BasePart") or obj:IsA("Model")) then return false end
	if obj:GetAttribute(State.Food.Id) == nil and obj:GetAttribute(State.Food.Type) == nil then return false end
	local anchor = obj.Parent
	if not anchor or anchor.Name ~= "SlotAnchor" then return false end
	local machine = anchor.Parent
	return machine ~= nil and machine:GetAttribute(State.Feed.Class) == "Patch"
end

local function foodPosition(food)
	if food:IsA("BasePart") then return food.Position end
	if food:IsA("Model") then return food:GetPivot().Position end
	return Vector3.zero
end

local function currentScaleFor(record)
	local xp = record.food:GetAttribute(State.Food.XP)
	local patchXP = record.machine and record.machine:GetAttribute(State.Feed.XP)
	return PatchScale.ComputeScale(xp, patchXP)
end

local function disconnectAll(record)
	for _, conn in ipairs(record.conns) do
		conn:Disconnect()
	end
	table.clear(record.conns)
end

local function cleanup(food)
	local record = tracked[food]
	if not record then return end
	disconnectAll(record)
	tracked[food] = nil
end

local function markDirty(record)
	record.dirty = true
end

local function applyScale(record)
	local food = record.food
	if not food:IsDescendantOf(Workspace) then
		cleanup(food)
		return
	end

	local scale = currentScaleFor(record)
	if record.lastScale and math.abs(record.lastScale - scale) < 0.0001 then
		record.dirty = false
		return
	end

	food:ScaleTo(scale)
	record.lastScale = scale
	record.dirty = false
end

local function addConnection(record, conn)
	if conn then
		table.insert(record.conns, conn)
	end
end

local function track(food)
	if tracked[food] or not isPatchSlotFood(food) then return end
	if not food:IsA("Model") then return end

	local machine = food.Parent and food.Parent.Parent
	if not machine then return end

	local record = {
		food = food,
		machine = machine,
		conns = {},
		dirty = true,
		lastScale = nil,
	}
	tracked[food] = record

	addConnection(record, RuntimeGuard.Connect(food:GetAttributeChangedSignal(State.Food.XP), "PatchSlotVisuals.FoodXPChanged", function()
		markDirty(record)
	end))
	addConnection(record, RuntimeGuard.Connect(machine:GetAttributeChangedSignal(State.Feed.XP), "PatchSlotVisuals.PatchXPChanged", function()
		markDirty(record)
	end))
	addConnection(record, RuntimeGuard.Connect(food.AncestryChanged, "PatchSlotVisuals.AncestryChanged", function()
		if not food:IsDescendantOf(Workspace) then
			cleanup(food)
		end
	end))
end

local function scanExisting()
	for _, obj in ipairs(Workspace:GetDescendants()) do
		if isPatchSlotFood(obj) then
			track(obj)
		end
	end
end

local function updateVisibleScales()
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local scaled = 0
	for food, record in pairs(tracked) do
		RuntimeGuard.Run("PatchSlotVisuals.UpdateRecord", function()
			if not food:IsDescendantOf(Workspace) then
				cleanup(food)
				return
			end
			if scaled >= MAX_SCALE_UPDATES_PER_STEP then return end

			local inRange = (foodPosition(food) - hrp.Position).Magnitude <= VISUAL_RANGE
			if inRange and record.dirty then
				applyScale(record)
				scaled += 1
			end
		end)
	end
end

function PatchSlotVisuals.start()
	scanExisting()

	RuntimeGuard.Connect(Workspace.DescendantAdded, "PatchSlotVisuals.DescendantAdded", function(obj)
		if isPatchSlotFood(obj) then
			track(obj)
		end
	end)

	local elapsed = 0
	RuntimeGuard.Connect(RunService.Heartbeat, "PatchSlotVisuals.Heartbeat", function(dt)
		elapsed += dt
		if elapsed < RANGE_CHECK_INTERVAL then return end
		elapsed = 0
		updateVisibleScales()
	end)
end

return PatchSlotVisuals
