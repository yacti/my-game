local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Inventory = require(Shared:WaitForChild("Inventory"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local InventoryFavouriteService = {}

local DEFAULT_RATE_SECONDS = 0.08

local started = false
local locksByUserId = {}
local lastRequestAtByUserId = {}

local resultRemote = Remotes.get(Remotes.Names.InventoryFavouriteResult)

local function userKey(player)
	return player and player.UserId or nil
end

local function validRequestId(requestId)
	return (type(requestId) == "string" and requestId ~= "" and #requestId <= 64)
		or (type(requestId) == "number" and requestId == requestId and math.abs(requestId) < math.huge)
end

local function sendResult(player, requestId, success, code, guid, favourite)
	resultRemote:FireClient(player, {
		requestId = requestId,
		success = success == true,
		code = code,
		guid = guid,
		favourite = favourite == true,
	})
end

local function takeRateLimit(player, interval)
	local key = userKey(player)
	if key == nil then
		return false
	end
	local now = os.clock()
	local previous = lastRequestAtByUserId[key] or 0
	if now - previous < interval then
		return false
	end
	lastRequestAtByUserId[key] = now
	return true
end

local function findOwnedToolByGuid(player, guid)
	if not ToolIdentity.IsValidGuid(guid) then
		return nil
	end

	local backpack = player and player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, child in ipairs(backpack:GetChildren()) do
			if child:IsA("Tool") and ToolIdentity.GuidOf(child) == guid then
				return child
			end
		end
	end

	local character = player and player.Character
	if character then
		for _, child in ipairs(character:GetChildren()) do
			if child:IsA("Tool") and ToolIdentity.GuidOf(child) == guid then
				return child
			end
		end
	end

	return nil
end

function InventoryFavouriteService.Start(config)
	if started then
		return
	end
	started = true

	config = config or {}
	local rateSeconds = tonumber(config.rateSeconds) or DEFAULT_RATE_SECONDS
	local snapshotFavouriteState = config.snapshotFavouriteState
	local isGameplayBlocked = type(config.isGameplayBlocked) == "function" and config.isGameplayBlocked or function()
		return false
	end
	assert(
		type(snapshotFavouriteState) == "function",
		"InventoryFavouriteService requires config.snapshotFavouriteState"
	)

	RuntimeGuard.Connect(
		Remotes.get(Remotes.Names.InventoryFavouriteRequest).OnServerEvent,
		"InventoryFavouriteService.Request",
		function(player, requestId, guid)
			if not validRequestId(requestId) or not ToolIdentity.IsValidGuid(guid) then
				sendResult(player, requestId, false, "invalid-request", guid, false)
				return
			end
			if not takeRateLimit(player, rateSeconds) then
				sendResult(player, requestId, false, "rate-limited", guid, false)
				return
			end

			local key = userKey(player)
			if key == nil then
				sendResult(player, requestId, false, "invalid-player", guid, false)
				return
			end
			if locksByUserId[key] then
				sendResult(player, requestId, false, "busy", guid, false)
				return
			end

			locksByUserId[key] = true
			local runOk = RuntimeGuard.Run("InventoryFavouriteService.Handler", function()
				local profile = PlayerDataService.GetProfile(player)
				if not profile then
					sendResult(player, requestId, false, "no-profile", guid, false)
					return
				end
				if isGameplayBlocked(player) then
					sendResult(player, requestId, false, "busy", guid, false)
					return
				end

				local tool = findOwnedToolByGuid(player, guid)
				if not Inventory.IsCountableTool(tool) then
					sendResult(player, requestId, false, "no-matching-tool", guid, false)
					return
				end

				local wasFavourite = ToolIdentity.IsFavourite(tool)
				local favourite = not wasFavourite
				ToolIdentity.SetFavourite(tool, favourite)
				local snapshotRunOk, snapshotSaved = RuntimeGuard.Run(
					"InventoryFavouriteService.Snapshot",
					snapshotFavouriteState,
					player,
					profile
				)
				if not snapshotRunOk or snapshotSaved ~= true then
					ToolIdentity.SetFavourite(tool, wasFavourite)
					sendResult(player, requestId, false, "snapshot-failed", guid, wasFavourite)
					return
				end

				sendResult(player, requestId, true, "ok", guid, favourite)
			end)
			locksByUserId[key] = nil
			if not runOk then
				sendResult(player, requestId, false, "server-error", guid, false)
			end
		end
	)

	RuntimeGuard.Connect(Players.PlayerRemoving, "InventoryFavouriteService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key ~= nil then
			locksByUserId[key] = nil
			lastRequestAtByUserId[key] = nil
		end
	end)
end

return InventoryFavouriteService
