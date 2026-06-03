local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlayerReplicaService = require(script.Parent:WaitForChild("PlayerReplicaService"))

local CurrencyService = {}

local currencyLocks = {}

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

local function publish(player, profile)
	RuntimeGuard.Run("CurrencyService.Publish", function()
		local amount = balance(profile)
		PlayerReplicaService.PublishCurrency(player, amount)
	end)
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

local function shouldPublish(deferPublish)
	return deferPublish ~= true
end

function CurrencyService.Publish(player, profile)
	publish(player, profile)
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
	if shouldPublish(deferPublish) then
		publish(player, profile)
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
	if shouldPublish(deferPublish) then
		publish(player, profile)
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
	if shouldPublish(deferPublish) then
		publish(player, profile)
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
	if shouldPublish(deferPublish) then
		publish(player, profile)
	end
	return true, nil, amount
end

return CurrencyService
