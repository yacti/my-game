local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local PlotService = require(Server:WaitForChild("PlotService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local PetIncomeService = {}

local SECONDS_PER_HOUR = 60 * 60
local LEADERSTATS_FOLDER_NAME = "leaderstats"
local INCOME_STAT_NAME = "$/second"
local LEGACY_CASH_STAT_NAMES = {
	["Cash"] = true,
	["$ Cash"] = true,
}

local started = false
local petCashMultiplier = function()
	return 1
end
local recordsByUserId = {}

local function userKey(player)
	return player and player.UserId or nil
end

local function finiteNonnegative(value, fallback)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return fallback or 0
	end
	return math.max(value, 0)
end

local function safeMultiplier(player)
	local ok, value = RuntimeGuard.Run("PetIncomeService.PetCashMultiplier", petCashMultiplier, player)
	if not ok then
		return 1
	end
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or value <= 0 or math.abs(value) == math.huge then
		return 1
	end
	return value
end

local function roundedNonnegativeInteger(value)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.max(math.floor(value + 0.5), 0)
end

local function ensureIncomeLeaderstat(player)
	if not (player and player:IsA("Player") and player:IsDescendantOf(Players)) then
		return nil
	end

	local leaderstats = player:FindFirstChild(LEADERSTATS_FOLDER_NAME)
	if leaderstats and not leaderstats:IsA("Folder") then
		warn("[PetIncomeService] Player " .. tostring(player.UserId) .. " has non-folder leaderstats")
		return nil
	end
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = LEADERSTATS_FOLDER_NAME
		leaderstats.Parent = player
	end

	for statName in pairs(LEGACY_CASH_STAT_NAMES) do
		local oldStat = leaderstats:FindFirstChild(statName)
		if oldStat then
			oldStat:Destroy()
		end
	end

	local income = leaderstats:FindFirstChild(INCOME_STAT_NAME)
	if income and not income:IsA("IntValue") then
		warn("[PetIncomeService] Player " .. tostring(player.UserId) .. " has non-IntValue income leaderstat")
		return nil
	end
	if not income then
		income = Instance.new("IntValue")
		income.Name = INCOME_STAT_NAME
		income.Parent = leaderstats
	end

	return income
end

local function syncIncomeLeaderstat(player, perSecond)
	RuntimeGuard.Run("PetIncomeService.SyncIncomeLeaderstat", function()
		local income = ensureIncomeLeaderstat(player)
		if income then
			income.Value = roundedNonnegativeInteger(perSecond)
		end
	end)
end

local function isPet(instance)
	return instance and instance:IsA("Model") and instance:GetAttribute(State.Pet.Index) ~= nil
end

local function disconnectAll(connections)
	for _, connection in ipairs(connections or {}) do
		if connection then
			connection:Disconnect()
		end
	end
	table.clear(connections)
end

local function recordFor(player)
	local key = userKey(player)
	return key and recordsByUserId[key] or nil
end

local function disconnectPet(record, pet)
	local connection = record and record.petConnections and record.petConnections[pet] or nil
	if connection then
		connection:Disconnect()
		record.petConnections[pet] = nil
	end
end

local function computeForPlot(player, plot)
	if not (player and plot) then
		return 0, 0
	end

	local basePerSecond = 0
	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		local rate = pet:GetAttribute(State.Pet.MoneyRate)
		if rate == nil then
			rate = 1
		end
		basePerSecond += finiteNonnegative(rate, 1)
	end

	local perSecond = basePerSecond * safeMultiplier(player)
	return perSecond, perSecond * SECONDS_PER_HOUR
end

function PetIncomeService.Compute(player, plot)
	return computeForPlot(player, plot or PlotService.GetPlayerPlot(player))
end

function PetIncomeService.Refresh(player)
	local record = recordFor(player)
	local plot = record and record.plot or PlotService.GetPlayerPlot(player)
	local perSecond, hourly = computeForPlot(player, plot)
	syncIncomeLeaderstat(player, perSecond)
	PlayerReplicaService.PublishHourlyPetIncome(player, hourly)
	return hourly
end

local function scheduleRefresh(record)
	if not record or record.refreshScheduled then
		return
	end
	record.refreshScheduled = true
	task.defer(function()
		if recordsByUserId[record.key] ~= record then
			return
		end
		record.refreshScheduled = false
		PetIncomeService.Refresh(record.player)
	end)
end

local function attachPet(record, pet)
	if not (record and isPet(pet)) or record.petConnections[pet] then
		return
	end
	record.petConnections[pet] = RuntimeGuard.Connect(
		pet:GetAttributeChangedSignal(State.Pet.MoneyRate),
		"PetIncomeService.MoneyRateChanged",
		function()
			scheduleRefresh(record)
		end
	)
end

local function untrackKey(key)
	local record = key and recordsByUserId[key] or nil
	if not record then
		return
	end
	recordsByUserId[key] = nil
	disconnectAll(record.connections)
	for pet in pairs(record.petConnections) do
		disconnectPet(record, pet)
	end
	syncIncomeLeaderstat(record.player, 0)
	PlayerReplicaService.PublishHourlyPetIncome(record.player, 0)
end

function PetIncomeService.TrackPlayerPlot(player, plot)
	local key = userKey(player)
	if not (key and plot) then
		return false
	end

	untrackKey(key)

	local record = {
		key = key,
		player = player,
		plot = plot,
		connections = {},
		petConnections = {},
		refreshScheduled = false,
	}
	recordsByUserId[key] = record

	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		attachPet(record, pet)
	end

	record.connections[#record.connections + 1] = RuntimeGuard.Connect(plot.ChildAdded, "PetIncomeService.PlotChildAdded", function(child)
		if isPet(child) then
			attachPet(record, child)
			scheduleRefresh(record)
		end
	end)
	record.connections[#record.connections + 1] = RuntimeGuard.Connect(plot.ChildRemoved, "PetIncomeService.PlotChildRemoved", function(child)
		if record.petConnections[child] then
			disconnectPet(record, child)
			scheduleRefresh(record)
		end
	end)

	PetIncomeService.Refresh(player)
	return true
end

function PetIncomeService.UntrackPlayer(player)
	untrackKey(userKey(player))
end

function PetIncomeService.Start(options)
	if started then
		return
	end
	started = true
	options = type(options) == "table" and options or {}
	if type(options.PetCashMultiplier) == "function" then
		petCashMultiplier = options.PetCashMultiplier
	end

	RuntimeGuard.Connect(Players.PlayerRemoving, "PetIncomeService.PlayerRemoving", function(player)
		PetIncomeService.UntrackPlayer(player)
	end)
end

return PetIncomeService
