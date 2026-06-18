local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlayerReplicaService = require(script.Parent:WaitForChild("PlayerReplicaService"))

local CurrencyService = {}

local LEADERSTATS_FOLDER_NAME = "leaderstats"
local CASH_STAT_NAME = "Cash"

local currencyLocks = {}
local currencyChangedCallbacks = {}

local function userKey(player)
	return player and player.UserId or nil
end

local function balance(profile)
	return profile and (tonumber(profile.Data.Currency) or 0) or 0
end

local function spendAmount(amount)
	amount = tonumber(amount) or 0
	if amount ~= amount or math.abs(amount) == math.huge then
		return 0
	end
	return math.max(math.floor(amount), 0)
end

local function ensureCashLeaderstat(player)
	if not (player and player:IsA("Player") and player:IsDescendantOf(Players)) then
		return nil
	end

	local leaderstats = player:FindFirstChild(LEADERSTATS_FOLDER_NAME)
	if leaderstats and not leaderstats:IsA("Folder") then
		warn("[CurrencyService] Player " .. tostring(player.UserId) .. " has non-folder leaderstats")
		return nil
	end
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = LEADERSTATS_FOLDER_NAME
		leaderstats.Parent = player
	end

	local cash = leaderstats:FindFirstChild(CASH_STAT_NAME)
	if cash and not cash:IsA("IntValue") then
		warn("[CurrencyService] Player " .. tostring(player.UserId) .. " has non-IntValue Cash leaderstat")
		return nil
	end
	if not cash then
		cash = Instance.new("IntValue")
		cash.Name = CASH_STAT_NAME
		cash.Parent = leaderstats
	end

	return cash
end

local function syncCashLeaderstat(player, amount)
	RuntimeGuard.Run("CurrencyService.SyncCashLeaderstat", function()
		local cash = ensureCashLeaderstat(player)
		if cash then
			cash.Value = spendAmount(amount)
		end
	end)
end

local function publish(player, profile)
	RuntimeGuard.Run("CurrencyService.Publish", function()
		local amount = balance(profile)
		syncCashLeaderstat(player, amount)
		PlayerReplicaService.PublishCurrency(player, amount)
	end)
end

local function notifyChanged(player, profile, amount)
	for _, callback in ipairs(currencyChangedCallbacks) do
		RuntimeGuard.Run("CurrencyService.CurrencyChangedCallback", callback, player, profile, amount)
	end
end

local function acquire(player)
	local key = userKey(player)
	if key == nil or currencyLocks[key] then
		return false
	end
	currencyLocks[key] = true
	return true
end

local function release(player)
	local key = userKey(player)
	if key ~= nil then
		currencyLocks[key] = nil
	end
end

RuntimeGuard.Connect(Players.PlayerRemoving, "CurrencyService.PlayerRemoving", release)

local function shouldPublish(deferPublish)
	return deferPublish ~= true
end

function CurrencyService.Publish(player, profile)
	publish(player, profile)
end

function CurrencyService.RegisterChangedCallback(callback)
	if type(callback) ~= "function" then
		return nil
	end
	table.insert(currencyChangedCallbacks, callback)
	local index = #currencyChangedCallbacks
	return function()
		if currencyChangedCallbacks[index] == callback then
			table.remove(currencyChangedCallbacks, index)
		end
	end
end

function CurrencyService.Add(player, profile, amount, deferPublish)
	amount = spendAmount(amount)
	if not profile or amount <= 0 then
		return balance(profile)
	end
	if not acquire(player) then
		return balance(profile), "busy"
	end

	profile.Data.Currency = balance(profile) + amount
	local updated = profile.Data.Currency
	release(player)
	notifyChanged(player, profile, updated)
	if shouldPublish(deferPublish) then
		publish(player, profile)
	else
		syncCashLeaderstat(player, updated)
	end
	return updated
end

function CurrencyService.TrySpend(player, profile, amount, deferPublish)
	amount = spendAmount(amount)
	if not profile then
		return false, "no-profile", 0
	end
	if amount <= 0 then
		return true, nil, balance(profile)
	end
	if not acquire(player) then
		return false, "busy", balance(profile)
	end

	local current = balance(profile)
	if current < amount then
		release(player)
		return false, "insufficient-currency", current
	end

	profile.Data.Currency = current - amount
	local updated = profile.Data.Currency
	release(player)
	notifyChanged(player, profile, updated)
	if shouldPublish(deferPublish) then
		publish(player, profile)
	else
		syncCashLeaderstat(player, updated)
	end
	return true, nil, updated
end

function CurrencyService.ResetToZeroForRebirth(player, profile, expectedMinimum, deferPublish)
	expectedMinimum = spendAmount(expectedMinimum)
	if not profile then
		return false, "no-profile", 0
	end
	if not acquire(player) then
		return false, "busy", balance(profile)
	end

	local current = balance(profile)
	if current < expectedMinimum then
		release(player)
		return false, "insufficient-currency", current
	end

	profile.Data.Currency = 0
	release(player)
	notifyChanged(player, profile, 0)
	if shouldPublish(deferPublish) then
		publish(player, profile)
	else
		syncCashLeaderstat(player, 0)
	end
	return true, nil, 0, current
end

function CurrencyService.SetBalanceForServer(player, profile, amount, deferPublish)
	amount = spendAmount(amount)
	if not profile then
		return false, "no-profile", 0
	end
	if not acquire(player) then
		return false, "busy", balance(profile)
	end

	profile.Data.Currency = amount
	release(player)
	notifyChanged(player, profile, amount)
	if shouldPublish(deferPublish) then
		publish(player, profile)
	else
		syncCashLeaderstat(player, amount)
	end
	return true, nil, amount
end

return CurrencyService
