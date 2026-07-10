local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local NotificationService = require(Server:WaitForChild("NotificationService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local SeedTools = require(Server:WaitForChild("SeedTools"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MediaReward = require(Shared:WaitForChild("MediaReward"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local MediaRewardService = {}

local REQUEST_RATE_SECONDS = 0.5

local started = false
local locks = {}
local lastRequestAt = {}
local resultRemote = nil

local function userKey(player)
	return player and player.UserId or nil
end

local function int(value)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.max(math.floor(value), 0)
end

local function sendResult(player, requestId, success, code)
	if resultRemote then
		resultRemote:FireClient(player, {
			requestId = requestId,
			success = success == true,
			code = code,
		})
	end
end

local function takeRateLimit(player)
	local key = userKey(player)
	if not key then
		return false
	end
	local now = os.clock()
	if now - (lastRequestAt[key] or 0) < REQUEST_RATE_SECONDS then
		return false
	end
	lastRequestAt[key] = now
	return true
end

local function saveProfile(profile)
	local ok = pcall(function()
		profile:Save()
	end)
	return ok
end

local function rollbackPrepared(profile, prepared)
	if type(prepared) ~= "table" then
		return
	end
	local seedId = prepared.seedId
	local amount = int(prepared.amount)
	local inventory = profile and profile.Data and profile.Data.SeedInventory
	if type(seedId) == "string" and amount > 0 and type(inventory) == "table" then
		inventory[seedId] = math.max(int(inventory[seedId]) - amount, 0)
		if inventory[seedId] <= 0 then
			inventory[seedId] = nil
		end
	end
	SeedTools.DestroyPrepared(prepared)
end

local function grantReward(player, profile)
	local reward = MediaReward.Reward or {}
	if reward.Type ~= MediaReward.RewardTypes.Seed then
		return false, "unsupported-reward", nil
	end
	local prepared, code = SeedTools.PrepareGrant(reward.Id, reward.Quantity)
	if not prepared then
		return false, code or "grant-failed", nil
	end
	local granted, grantCode = SeedTools.ApplyPrepared(player, profile, prepared)
	if not granted then
		return false, grantCode or "grant-failed", nil
	end
	return true, "ok", prepared
end

local function redeem(player, requestId, codeText)
	requestId = int(requestId)
	if requestId <= 0 then
		return
	end
	if not takeRateLimit(player) then
		sendResult(player, requestId, false, "rate-limited")
		return
	end

	-- The bot's codes are recognized purely by composition, so re-validate the
	-- exact spec here: the client-side check is only a convenience.
	if not MediaReward.ValidateCode(codeText) then
		NotificationService.Error(player, MediaReward.InvalidCodeMessage)
		sendResult(player, requestId, false, "invalid-code")
		return
	end

	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		NotificationService.Error(player, "Could not verify the code yet")
		sendResult(player, requestId, false, "no-profile")
		return
	end
	if profile.Data.MediaRewardCollected == true then
		NotificationService.Error(player, MediaReward.AlreadyCollectedMessage)
		PlayerReplicaService.PublishMediaRewardCollected(player, profile)
		sendResult(player, requestId, false, "already-collected")
		return
	end

	local key = userKey(player)
	if not key or locks[key] then
		sendResult(player, requestId, false, "busy")
		return
	end

	locks[key] = true
	local wasCollected = profile.Data.MediaRewardCollected == true
	local prepared = nil
	local granted = false
	local resultCode = "server-error"

	local ok, err = pcall(function()
		granted, resultCode, prepared = grantReward(player, profile)
		if not granted then
			return
		end

		profile.Data.MediaRewardCollected = true
		resultCode = "save-failed"
		if not saveProfile(profile) then
			profile.Data.MediaRewardCollected = wasCollected
			rollbackPrepared(profile, prepared)
			granted = false
			return
		end
		resultCode = "ok"
	end)

	locks[key] = nil

	if not ok then
		warn("[MediaRewardService] Reward grant failed: " .. tostring(err))
		profile.Data.MediaRewardCollected = wasCollected
		if granted and prepared then
			rollbackPrepared(profile, prepared)
			granted = false
		end
		resultCode = "server-error"
	end

	PlayerReplicaService.PublishInventories(player, profile)
	PlayerReplicaService.PublishMediaRewardCollected(player, profile)

	if resultCode == "ok" then
		NotificationService.Success(player, MediaReward.SuccessMessage)
	elseif resultCode == "inventory-full" then
		-- ToolGrantService already sends the inventory cap notification.
	elseif resultCode == "no-backpack" then
		NotificationService.Error(player, "Could not verify the code yet. Please rejoin and try again")
	else
		NotificationService.Error(player, "Could not verify the code yet")
		warn("[MediaRewardService] Reward grant failed: " .. tostring(resultCode))
	end

	sendResult(player, requestId, resultCode == "ok", resultCode)
end

function MediaRewardService.Start()
	if started then
		return
	end
	started = true

	resultRemote = Remotes.get(Remotes.Names.MediaRewardRedeemResult)

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.MediaRewardRedeemRequest).OnServerEvent, "MediaRewardService.Redeem", function(player, requestId, codeText)
		redeem(player, requestId, codeText)
	end)
	RuntimeGuard.Connect(Players.PlayerRemoving, "MediaRewardService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			locks[key] = nil
			lastRequestAt[key] = nil
		end
	end)
end

return MediaRewardService
