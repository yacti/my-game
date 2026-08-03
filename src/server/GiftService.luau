local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local FoodInventoryService = require(Server:WaitForChild("FoodInventoryService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local OnboardingService = require(Server:WaitForChild("OnboardingService"))
local PetSkinTools = require(Server:WaitForChild("PetSkinTools"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService = require(Server:WaitForChild("PlotService"))
local TelemetryService = require(Server:WaitForChild("TelemetryService"))
local ToolGrantService = require(Server:WaitForChild("ToolGrantService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
local Inventory = require(Shared:WaitForChild("Inventory"))
local PlayerSettings = require(Shared:WaitForChild("PlayerSettings"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local GiftService = {}

local DEFAULT_RATE_SECONDS = 0.5
-- Prompt shows at 10 studs; the extra slack covers movement while the
-- giver's confirm dialog is open.
local GIFT_DISTANCE = 15
local PAIR_COOLDOWN_SECONDS = 5
local RECEIVE_COOLDOWN_SECONDS = 1

local started = false
local locksByUserId = {}
local lastRequestAtByUserId = {}
local lastReceiveAtByUserId = {}
local pairCooldownAtByGiverId = {}

local resultRemote = Remotes.get(Remotes.Names.GiftResult)

local function userKey(player)
	return player and player.UserId or nil
end

local function displayName(player)
	return player and player.DisplayName or player and player.Name or "Player"
end

local function sendResult(player, requestId, success, code, extra)
	resultRemote:FireClient(player, {
		requestId = requestId,
		success = success == true,
		code = code,
		itemName = extra and extra.itemName or nil,
		recipientName = extra and extra.recipientName or nil,
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

-- Nonzero integers only: Studio local-server test clients use negative
-- UserIds, so sign is not validated here; Players:GetPlayerByUserId is the
-- authority on whether the target exists.
local function isValidUserId(value)
	return type(value) == "number" and value == value and value % 1 == 0 and value ~= 0
end

local function characterRoot(player)
	local character = player and player.Character
	return character and character:FindFirstChild("HumanoidRootPart") or nil
end

-- Only patch/tree harvests and unapplied Pet Skin inventory tools are
-- giftable. Applied skins are pet data, not Tools, so they never enter this
-- path. Jam (processor-made) and every other non-food tool remain blocked.
local function isGiftableTool(item)
	if not (item and item:IsA("Tool")) then
		return false
	end
	return (Food.IsFood(item) and not Food.IsJamFoodId(Food.IdOf(item)))
		or PetSkinTools.IsPetSkinTool(item)
end

-- The descriptor is both the mint recipe for the recipient's copy and the
-- rollback recipe if a snapshot fails after the giver's tool is destroyed.
local function describeTool(tool)
	local record = FoodInventoryService.SerializeTool(tool)
	if record then
		return { kind = "food", itemId = record.foodId, record = record }
	end
	local petSkinId = PetSkinTools.PetSkinIdOf(tool)
	if petSkinId then
		return {
			kind = "pet-skin",
			itemId = petSkinId,
			petSkinId = petSkinId,
			guid = ToolIdentity.GuidOf(tool),
			favourite = ToolIdentity.IsFavourite(tool),
		}
	end
	return nil
end

local function mintFromDescriptor(descriptor, forRecipient)
	if descriptor.kind == "food" then
		local record = table.clone(descriptor.record)
		if forRecipient then
			-- Fresh guid for the recipient's copy; the giver's profile still
			-- references the old guid until their snapshot lands. Favourite state is
			-- the giver's preference, so it does not transfer to the recipient.
			record.guid = nil
			record.favourite = nil
		end
		return FoodInventoryService.MakeTool(record)
	end
	if descriptor.kind == "pet-skin" then
		local tool = PetSkinTools.MakePetSkinTool(descriptor.petSkinId)
		if tool and not forRecipient then
			-- Rollback restores the giver's exact inventory identity and favourite
			-- preference. The recipient keeps the fresh guid made above and never
			-- inherits the giver's favourite state.
			tool:SetAttribute(State.Tool.Guid, descriptor.guid)
			ToolIdentity.SetFavourite(tool, descriptor.favourite)
		end
		return tool
	end
	return nil
end

function GiftService.Start(config)
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
	assert(type(snapshotProfileState) == "function", "GiftService requires config.snapshotProfileState")

	-- Re-grants the giver's item after their tool was destroyed but the
	-- transfer could not complete (FeedPlacementService.restoreConsumedTool
	-- pattern). Default auto-equip restores the held state the giver had.
	local function restoreGiverTool(giver, descriptor)
		local replacement = mintFromDescriptor(descriptor, false)
		if not replacement then
			return false, "no-replacement"
		end
		local restored, code = ToolGrantService.GrantTool(giver, replacement)
		if not restored then
			replacement:Destroy()
			return false, code
		end
		return true
	end

	local function handleGift(giver, giverKey, recipient, recipientKey, requestId, toolGuid)
		local giverProfile = PlayerDataService.GetProfile(giver)
		if not giverProfile then
			sendResult(giver, requestId, false, "no-profile")
			return
		end
		if isGameplayBlocked(giver) then
			sendResult(giver, requestId, false, "busy")
			return
		end
		local recipientProfile = PlayerDataService.GetProfile(recipient)
		if not recipientProfile then
			sendResult(giver, requestId, false, "recipient-not-ready")
			return
		end
		-- Covers death (InventoryRestorePending) and offline-progress on the
		-- recipient: never grant into a backpack a respawn is about to rebuild.
		if isGameplayBlocked(recipient) then
			sendResult(giver, requestId, false, "recipient-busy")
			return
		end
		if OnboardingService.IsActive(giverProfile) then
			sendResult(giver, requestId, false, "onboarding")
			return
		end
		if OnboardingService.IsActive(recipientProfile) then
			sendResult(giver, requestId, false, "recipient-onboarding")
			return
		end
		-- The giver's client hides the prompt via the AcceptGiftsDisabled
		-- attribute; the profile stays authoritative here.
		if not PlayerSettings.Get(recipientProfile.Data.PlayerSettings, PlayerSettings.Keys.AcceptGifts) then
			sendResult(giver, requestId, false, "recipient-not-accepting")
			return
		end

		local now = os.clock()
		local pairCooldowns = pairCooldownAtByGiverId[giverKey]
		local pairAt = pairCooldowns and pairCooldowns[recipientKey]
		if pairAt and now - pairAt < PAIR_COOLDOWN_SECONDS then
			sendResult(giver, requestId, false, "rate-limited")
			return
		end
		local receiveAt = lastReceiveAtByUserId[recipientKey]
		if receiveAt and now - receiveAt < RECEIVE_COOLDOWN_SECONDS then
			sendResult(giver, requestId, false, "rate-limited")
			return
		end

		local giverPlot = PlotService.GetPlayerPlot(giver)
		if not giverPlot then
			sendResult(giver, requestId, false, "no-plot")
			return
		end
		local recipientPlot = PlotService.GetPlayerPlot(recipient)
		if not recipientPlot then
			sendResult(giver, requestId, false, "recipient-no-plot")
			return
		end
		local giverRoot = characterRoot(giver)
		if not giverRoot then
			sendResult(giver, requestId, false, "no-character")
			return
		end
		local recipientRoot = characterRoot(recipient)
		if not recipientRoot then
			sendResult(giver, requestId, false, "recipient-no-character")
			return
		end
		if (giverRoot.Position - recipientRoot.Position).Magnitude > GIFT_DISTANCE then
			sendResult(giver, requestId, false, "too-far")
			return
		end

		local tool = ToolIdentity.FindEquippedByGuid(giver, toolGuid)
		if not tool then
			sendResult(giver, requestId, false, "not-holding")
			return
		end
		if not isGiftableTool(tool) then
			sendResult(giver, requestId, false, "not-giftable")
			return
		end
		if Inventory.RemainingSlots(recipient) <= 0 then
			NotificationService.Error(giver, string.format("%s's inventory is full", displayName(recipient)))
			sendResult(giver, requestId, false, "recipient-inventory-full")
			return
		end

		local descriptor = describeTool(tool)
		if not descriptor then
			sendResult(giver, requestId, false, "invalid-tool")
			return
		end
		local itemName = tool.Name

		local mintedTool = nil
		local giverToolDestroyed = false

		local function runTransfer()
			mintedTool = mintFromDescriptor(descriptor, true)
			if not mintedTool then
				return false, "mint-failed"
			end
			-- Minting can yield on a cold asset cache; re-resolve so the
			-- giver still holds the exact tool before anything is destroyed.
			local liveTool = ToolIdentity.FindEquippedByGuid(giver, toolGuid, isGiftableTool)
			if not liveTool then
				mintedTool:Destroy()
				return false, "not-holding"
			end
			-- Grant before destroy: every failure past this point can be
			-- rolled back by destroying the still-parented fresh tool,
			-- whereas destroy-first risks losing the item outright.
			local granted, grantCode = ToolGrantService.GrantTool(recipient, mintedTool, { autoEquip = false })
			if not granted then
				mintedTool:Destroy()
				if grantCode == "no-backpack" then
					return false, "recipient-gone"
				end
				return false, "recipient-inventory-full"
			end
			if not ToolIdentity.DestroyIfGuidMatches(liveTool, toolGuid) then
				mintedTool:Destroy()
				return false, "not-holding"
			end
			giverToolDestroyed = true

			if not snapshotProfileState(giver, giverPlot, giverProfile) then
				if mintedTool.Parent then
					mintedTool:Destroy()
				end
				local restored, restoreCode = restoreGiverTool(giver, descriptor)
				if restored then
					giverToolDestroyed = false
				else
					TelemetryService.Warn("gift_restore_failed", TelemetryService.ForPlayer(giver, {
						recipientUserId = recipientKey,
						kind = descriptor.kind,
						itemId = descriptor.itemId,
						code = restoreCode,
					}))
					NotificationService.Error(giver, "Something went wrong completing the gift")
				end
				return false, "save-failed"
			end
			-- Giver's profile no longer holds the item; if the recipient's
			-- snapshot refuses (e.g. they died in a race), unwind both sides.
			if not snapshotProfileState(recipient, recipientPlot, recipientProfile) then
				if mintedTool.Parent then
					mintedTool:Destroy()
				end
				local restored, restoreCode = restoreGiverTool(giver, descriptor)
				if restored then
					giverToolDestroyed = false
					if not snapshotProfileState(giver, giverPlot, giverProfile) then
						TelemetryService.Warn("gift_rollback_snapshot_failed", TelemetryService.ForPlayer(giver, {
							recipientUserId = recipientKey,
							kind = descriptor.kind,
							itemId = descriptor.itemId,
						}))
					end
				else
					TelemetryService.Warn("gift_restore_failed", TelemetryService.ForPlayer(giver, {
						recipientUserId = recipientKey,
						kind = descriptor.kind,
						itemId = descriptor.itemId,
						code = restoreCode,
					}))
					NotificationService.Error(giver, "Something went wrong completing the gift")
				end
				return false, "save-failed"
			end
			return true, "ok"
		end

		local ok, success, code = pcall(runTransfer)
		if not ok then
			warn("[GiftService] Transfer failed for user " .. tostring(giverKey) .. ": " .. tostring(success))
			if mintedTool and mintedTool.Parent then
				mintedTool:Destroy()
			end
			if giverToolDestroyed then
				local restored = restoreGiverTool(giver, descriptor)
				if not restored then
					TelemetryService.Warn("gift_restore_failed", TelemetryService.ForPlayer(giver, {
						recipientUserId = recipientKey,
						kind = descriptor.kind,
						itemId = descriptor.itemId,
						code = "transfer-error",
					}))
					NotificationService.Error(giver, "Something went wrong completing the gift")
				end
			end
			sendResult(giver, requestId, false, "server-error")
			return
		end
		if not success then
			sendResult(giver, requestId, false, code)
			return
		end

		local pairMap = pairCooldownAtByGiverId[giverKey]
		if not pairMap then
			pairMap = {}
			pairCooldownAtByGiverId[giverKey] = pairMap
		end
		pairMap[recipientKey] = os.clock()
		lastReceiveAtByUserId[recipientKey] = os.clock()

		NotificationService.Success(recipient, string.format("%s gifted you %s!", displayName(giver), itemName))
		NotificationService.Success(giver, string.format("Gifted %s to %s!", itemName, displayName(recipient)))
		TelemetryService.Record("gift_sent", TelemetryService.ForPlayer(giver, {
			recipientUserId = recipientKey,
			kind = descriptor.kind,
			itemId = descriptor.itemId,
		}))
		sendResult(giver, requestId, true, "ok", {
			itemName = itemName,
			recipientName = displayName(recipient),
		})
	end

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.GiftRequest).OnServerEvent, "GiftService.Request", function(giver, requestId, targetUserId, toolGuid)
		if type(requestId) ~= "number" then
			return
		end
		if not takeRateLimit(giver, rateSeconds) then
			sendResult(giver, requestId, false, "rate-limited")
			return
		end
		local giverKey = userKey(giver)
		if giverKey == nil then
			sendResult(giver, requestId, false, "invalid-player")
			return
		end
		if not isValidUserId(targetUserId) or targetUserId == giverKey then
			sendResult(giver, requestId, false, "invalid-target")
			return
		end
		if not ToolIdentity.IsValidGuid(toolGuid) then
			sendResult(giver, requestId, false, "invalid-tool")
			return
		end
		if locksByUserId[giverKey] then
			sendResult(giver, requestId, false, "busy")
			return
		end
		local recipient = Players:GetPlayerByUserId(targetUserId)
		if not (recipient and recipient.Parent == Players) then
			sendResult(giver, requestId, false, "recipient-gone")
			return
		end
		local recipientKey = userKey(recipient)
		if recipientKey == nil then
			sendResult(giver, requestId, false, "recipient-gone")
			return
		end
		-- Lock both parties so simultaneous A->B and B->A gifts cannot
		-- interleave; the second request fails with "busy".
		if locksByUserId[recipientKey] then
			sendResult(giver, requestId, false, "busy")
			return
		end

		locksByUserId[giverKey] = true
		locksByUserId[recipientKey] = true
		RuntimeGuard.Run("GiftService.Handler", function()
			handleGift(giver, giverKey, recipient, recipientKey, requestId, toolGuid)
		end)
		locksByUserId[giverKey] = nil
		locksByUserId[recipientKey] = nil
	end)

	RuntimeGuard.Connect(Players.PlayerRemoving, "GiftService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key == nil then
			return
		end
		locksByUserId[key] = nil
		lastRequestAtByUserId[key] = nil
		lastReceiveAtByUserId[key] = nil
		pairCooldownAtByGiverId[key] = nil
		for _, byRecipient in pairs(pairCooldownAtByGiverId) do
			byRecipient[key] = nil
		end
	end)
end

return GiftService
