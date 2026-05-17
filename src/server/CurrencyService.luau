local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local CurrencyService = {}

local CurrencyUpdated = Remotes.get(Remotes.Names.CurrencyUpdated)
local spendLocks = {}

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
	CurrencyUpdated:FireClient(player, balance(profile))
end

function CurrencyService.Add(player, profile, amount)
	amount = tonumber(amount) or 0
	if not profile or amount <= 0 then
		return balance(profile)
	end

	profile.Data.Currency = balance(profile) + amount
	publish(player, profile)
	return profile.Data.Currency
end

function CurrencyService.TrySpend(player, profile, amount)
	amount = spendAmount(amount)
	if not profile then
		return false, "no-profile", 0
	end
	if amount <= 0 then
		return true, nil, balance(profile)
	end
	if spendLocks[player] then
		return false, "busy", balance(profile)
	end

	spendLocks[player] = true
	local current = balance(profile)
	if current < amount then
		spendLocks[player] = nil
		return false, "insufficient-currency", current
	end

	profile.Data.Currency = current - amount
	local updated = profile.Data.Currency
	spendLocks[player] = nil
	publish(player, profile)
	return true, nil, updated
end

return CurrencyService
