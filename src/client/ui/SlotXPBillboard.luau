-- Renders an XP billboard above each growing slot food. Visible while the
-- player's HumanoidRootPart is within RANGE studs of the food. Range is gated
-- against the player (not the camera) on a 0.2s tick — BillboardGui.MaxDistance
-- is camera-based and would hide legitimate slots when the camera is pulled
-- back.
--
-- Identification: patch slot food is any BasePart/Model with a FoodType
-- attribute that lives under a Patch machine's SlotAnchor. Tree machines also
-- use SlotAnchor for on-branch fruit, but those visuals should not get this UI.
-- Slot XP is derived locally via PatchGrowth from the replicated base XP and
-- growth-start attributes; the label only re-renders for visible billboards
-- whose derived value changed.
--
-- Discovery is plot-scoped via PlotScope (assigned plot + plots near the
-- character), and BillboardGuis are created lazily on range entry and destroyed
-- on range exit, so the GUI count tracks what is actually visible instead of
-- every slot on every plot.
--
-- Per-viewer rendered locally; no replication of GUI instances.

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local PatchGrowth = require(Shared:WaitForChild("PatchGrowth"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))
local PlotScope = require(script.Parent:WaitForChild("PlotScope"))
local XPBillboardTemplate = require(script.Parent:WaitForChild("XPBillboardTemplate"))

local RANGE = 10
local SCOPE_RANGE = 20
local UPDATE_INTERVAL = 0.2

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local tracked   = {}  -- [food] = { machine, conns, gui, label, lastXP }

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

local function dropGui(record)
	if record.gui then
		record.gui:Destroy()
	end
	record.gui = nil
	record.label = nil
	record.lastXP = nil
end

local function cleanup(food)
	local record = tracked[food]
	if not record then return end
	for _, conn in ipairs(record.conns) do
		conn:Disconnect()
	end
	dropGui(record)
	tracked[food] = nil
end

local function track(food)
	if tracked[food] then return end

	local record = {
		machine = food.Parent and food.Parent.Parent or nil,
		conns = {},
		gui = nil,
		label = nil,
		lastXP = nil,
	}
	tracked[food] = record

	local conn = RuntimeGuard.Connect(food.AncestryChanged, "SlotXPBillboard.AncestryChanged", function()
		if not food:IsDescendantOf(Workspace) then cleanup(food) end
	end)
	if conn then
		table.insert(record.conns, conn)
	end
end

-- Lazily creates the BillboardGui on range entry. The gui is destroyed again on
-- range exit (and by PlayerGui resets on respawn); the record survives either
-- way, so the billboard always comes back on the next in-range tick.
local function ensureGui(food, record)
	if record.gui and record.gui:IsDescendantOf(playerGui) then return true end

	dropGui(record)
	local adornee = adorneeFor(food)
	if not adornee then return false end

	local gui, label = XPBillboardTemplate.Clone("SlotXPBillboard")
	if not gui then return false end

	gui.Name = "XPBillboard"
	gui.Adornee = adornee
	gui.Parent = playerGui
	record.gui = gui
	record.label = label
	return true
end

local function scanRoot(root)
	for _, d in ipairs(root:GetDescendants()) do
		if isSlotFood(d) then track(d) end
	end
end

local function updateBillboards()
	local char = player.Character
	local hrp  = char and char:FindFirstChild("HumanoidRootPart")
	local now  = Workspace:GetServerTimeNow()
	for food, record in pairs(tracked) do
		if not food:IsDescendantOf(Workspace) then
			cleanup(food)
		elseif hrp and (foodPosition(food) - hrp.Position).Magnitude <= RANGE then
			if ensureGui(food, record) then
				local xp = PatchGrowth.ComputeXPForFood(food, record.machine, now)
				if xp ~= record.lastXP then
					record.lastXP = xp
					record.label.Text = NumberFormatter.XP(xp, " xp")
				end
			end
		else
			dropGui(record)
		end
	end
end

function SlotXPBillboard.start()
	PlotScope.Bind({
		label = "SlotXPBillboard",
		nearbyRange = SCOPE_RANGE,
		onPlotAdded = function(plot)
			scanRoot(plot)
			local conn = RuntimeGuard.Connect(plot.DescendantAdded, "SlotXPBillboard.PlotDescendantAdded", function(d)
				if isSlotFood(d) then track(d) end
			end)
			return function()
				if conn then conn:Disconnect() end
				for food in pairs(tracked) do
					if food:IsDescendantOf(plot) then cleanup(food) end
				end
			end
		end,
	})

	local elapsed = 0
	RuntimeGuard.Connect(RunService.Heartbeat, "SlotXPBillboard.Heartbeat", function(dt)
		elapsed += dt
		if elapsed < UPDATE_INTERVAL then return end
		elapsed = 0
		updateBillboards()
	end)
end

return SlotXPBillboard
