local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local NotificationService = require(Server:WaitForChild("NotificationService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService = require(Server:WaitForChild("PlotService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Inventory = require(Shared:WaitForChild("Inventory"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local InventoryDeleteService = {}

local DEFAULT_RATE_SECONDS = 0.35

local started = false
local locksByUserId = {}
local lastRequestAtByUserId = {}

local resultRemote = Remotes.get(Remotes.Names.InventoryDeleteResult)

local function userKey(player)
	return player and player.UserId or nil
end

local function sendResult(player, requestId, success, code, deletedCount, skippedCount)
	resultRemote:FireClient(player, {
		requestId = requestId,
		success = success == true,
		code = code,
		deletedCount = deletedCount or 0,
		skippedCount = skippedCount or 0,
		remainingSlots = Inventory.RemainingSlots(player),
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

local function normalizeGuids(rawGuids)
	if type(rawGuids) ~= "table" then
		return nil, "invalid-guids"
	end

	local guids = {}
	local seen = {}
	for _, guid in ipairs(rawGuids) do
		if ToolIdentity.IsValidGuid(guid) and not seen[guid] then
			guids[#guids + 1] = guid
			seen[guid] = true
			if #guids > Inventory.MAX_ITEMS then
				return nil, "too-many"
			end
		end
	end

	if #guids == 0 then
		return nil, "empty"
	end
	return guids, "ok"
end

function InventoryDeleteService.Start(config)
	if started then
		return
	end
	started = true

	config = config or {}
	local rateSeconds = tonumber(config.rateSeconds) or DEFAULT_RATE_SECONDS
	local snapshotProfileState = config.snapshotProfileState
	local isGameplayBlocked = type(config.isGameplayBlocked) == "function" and config.isGameplayBlocked or function()
		return false
	end

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.InventoryDeleteRequest).OnServerEvent, "InventoryDeleteService.Request", function(player, requestId, rawGuids)
		if not takeRateLimit(player, rateSeconds) then
			sendResult(player, requestId, false, "rate-limited")
			return
		end

		local key = userKey(player)
		if key == nil then
			sendResult(player, requestId, false, "invalid-player")
			return
		end
		if locksByUserId[key] then
			sendResult(player, requestId, false, "busy")
			return
		end

		local guids, normalizeCode = normalizeGuids(rawGuids)
		if not guids then
			sendResult(player, requestId, false, normalizeCode)
			return
		end

		locksByUserId[key] = true
		RuntimeGuard.Run("InventoryDeleteService.Handler", function()
			local profile = PlayerDataService.GetProfile(player)
			local plot = PlotService.GetPlayerPlot(player)
			if not profile then
				sendResult(player, requestId, false, "no-profile")
				return
			end
			if not plot then
				sendResult(player, requestId, false, "no-plot")
				return
			end
			if isGameplayBlocked(player) then
				sendResult(player, requestId, false, "busy")
				return
			end

			local deletedCount = 0
			local skippedCount = 0
			for _, guid in ipairs(guids) do
				local tool = findOwnedToolByGuid(player, guid)
				if Inventory.IsCountableTool(tool) and not ToolIdentity.IsFavourite(tool) then
					tool:Destroy()
					deletedCount += 1
				else
					skippedCount += 1
				end
			end

			if deletedCount <= 0 then
				sendResult(player, requestId, false, "no-matching-tools", deletedCount, skippedCount)
				return
			end

			if type(snapshotProfileState) == "function" then
				local snapshotOk = snapshotProfileState(player, plot, profile)
				if not snapshotOk then
					warn("[InventoryDeleteService] Snapshot failed after inventory deletion for user " .. tostring(key))
					sendResult(player, requestId, false, "snapshot-failed", deletedCount, skippedCount)
					return
				end
			end

			NotificationService.Success(player, string.format("Deleted %d item%s", deletedCount, deletedCount == 1 and "" or "s"))
			sendResult(player, requestId, true, "ok", deletedCount, skippedCount)
		end)
		locksByUserId[key] = nil
	end)

	RuntimeGuard.Connect(Players.PlayerRemoving, "InventoryDeleteService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key ~= nil then
			locksByUserId[key] = nil
			lastRequestAtByUserId[key] = nil
		end
	end)
end

return InventoryDeleteService
