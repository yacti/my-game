local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShopBalance = require(ReplicatedStorage.Shared:WaitForChild("ShopBalance"))

local PlayerBonuses = {}

PlayerBonuses.FriendBoostPercentPerFriend = 10
PlayerBonuses.MaxFriendBoostFriends = 4

local function finiteNumber(value, fallback)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return fallback or 0
	end
	return value
end

local function owned(ownership, key)
	return type(ownership) == "table" and type(key) == "string" and ownership[key] == true
end

local function addMultiplierTerm(total, multiplier)
	multiplier = finiteNumber(multiplier, 1)
	if multiplier <= 1 then
		return total
	end
	return total + (multiplier - 1)
end

function PlayerBonuses.IsGamePassOwned(ownership, key)
	return owned(ownership, key)
end

function PlayerBonuses.EffectiveMultiplier(...)
	local total = 1
	for index = 1, select("#", ...) do
		total = addMultiplierTerm(total, select(index, ...))
	end
	return math.max(total, 1)
end

function PlayerBonuses.FriendBoostFriendCount(friendCount)
	friendCount = math.floor(finiteNumber(friendCount, 0))
	return math.clamp(friendCount, 0, PlayerBonuses.MaxFriendBoostFriends)
end

function PlayerBonuses.FriendBoostPercent(friendCount)
	return PlayerBonuses.FriendBoostFriendCount(friendCount) * PlayerBonuses.FriendBoostPercentPerFriend
end

function PlayerBonuses.FriendBoostMultiplier(friendCount)
	return 1 + (PlayerBonuses.FriendBoostPercent(friendCount) / 100)
end

function PlayerBonuses.PetCashMultiplier(ownership)
	local total = 1
	for _, pass in ipairs(ShopBalance.AllGamePasses()) do
		if owned(ownership, pass.Key) then
			total = addMultiplierTerm(total, pass.PetCashMultiplier)
		end
	end
	return math.max(total, 1)
end

function PlayerBonuses.FoodXPMultiplier(ownership)
	local total = 1
	for _, pass in ipairs(ShopBalance.AllGamePasses()) do
		if owned(ownership, pass.Key) then
			total = addMultiplierTerm(total, pass.FoodXPMultiplier)
		end
	end
	return math.max(total, 1)
end

function PlayerBonuses.LuckBonusPercent(ownership)
	local total = 0
	for _, pass in ipairs(ShopBalance.AllGamePasses()) do
		if owned(ownership, pass.Key) then
			total += math.max(finiteNumber(pass.LuckBonusPercent, 0), 0)
		end
	end
	return total
end

return PlayerBonuses
