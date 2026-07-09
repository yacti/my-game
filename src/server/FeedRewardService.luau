local DiscoveryService = require(script.Parent:WaitForChild("DiscoveryService"))
local FeedMachineTools = require(script.Parent:WaitForChild("FeedMachineTools"))
local ToolGrantService = require(script.Parent:WaitForChild("ToolGrantService"))

local FeedRewardService = {}

local function amountOrZero(amount)
	amount = tonumber(amount) or 0
	if type(amount) ~= "number" or amount ~= amount or math.abs(amount) == math.huge then
		return 0
	end
	return math.max(math.floor(amount), 0)
end

local function destroyPrepared(prepared)
	if type(prepared) ~= "table" then
		return
	end
	for _, tool in ipairs(prepared.tools or {}) do
		if tool then
			tool:Destroy()
		end
	end
end

function FeedRewardService.PrepareGrant(feedType, amount)
	amount = amountOrZero(amount)
	if type(feedType) ~= "string" or feedType == "" then
		return nil, "invalid-feed"
	end
	if amount <= 0 then
		return nil, "invalid-amount"
	end

	local tools = {}
	for _ = 1, amount do
		local tool = FeedMachineTools.MakeFeedTool(feedType)
		if not tool then
			destroyPrepared({ tools = tools })
			return nil, "no-template"
		end
		tools[#tools + 1] = tool
	end

	return {
		feedType = feedType,
		amount = amount,
		tools = tools,
	}
end

function FeedRewardService.ApplyPrepared(player, profile, prepared)
	if not (player and profile and type(prepared) == "table") then
		return false, "invalid-grant"
	end
	local feedType = prepared.feedType
	local amount = amountOrZero(prepared.amount)
	if type(feedType) ~= "string" or feedType == "" or amount <= 0 then
		destroyPrepared(prepared)
		return false, "invalid-grant"
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		destroyPrepared(prepared)
		return false, "no-backpack"
	end

	local granted, code = ToolGrantService.GrantTools(player, prepared.tools)
	if not granted then
		destroyPrepared(prepared)
		return false, code
	end

	profile.Data.FeedInventory = profile.Data.FeedInventory or {}
	profile.Data.FeedInventory[feedType] = (profile.Data.FeedInventory[feedType] or 0) + amount
	DiscoveryService.MarkFeedType(player, profile, feedType)
	return true
end

function FeedRewardService.DestroyPrepared(prepared)
	destroyPrepared(prepared)
end

function FeedRewardService.Grant(player, profile, feedType, amount)
	local prepared, code = FeedRewardService.PrepareGrant(feedType, amount or 1)
	if not prepared then
		return false, code
	end
	return FeedRewardService.ApplyPrepared(player, profile, prepared)
end

return FeedRewardService
