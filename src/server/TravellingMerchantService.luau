-- The Travelling Merchant: the hourly carriage at Workspace.Map.MerchantEvent.
--
-- Three jobs:
--
-- 1. Presence. The GameEvents handler calls StartMerchant/StopMerchant, which
--    clone ReplicatedStorage.Assets.GameEvents.MerchantEvent into Workspace.Map
--    and destroy it again. The template is authored in place, so the clone keeps
--    its CFrames. StartsAt/EndsAt are stamped on the folder so the carriage's
--    billboard can count down without a remote.
--
-- 2. Trades. The client sends an offerId; the server re-derives which offers are
--    live from the record's startsAt (never trusting the client's idea of what
--    is on sale), consumes the requested food, grants the reward and marks the
--    offer claimed for this visit.
--
-- 3. Skips. One DevProduct per offer slot buys the reward outright without
--    consuming anything. Reservation-then-receipt, same shape as GrowSkip, so a
--    player who pays is never left with nothing.
--
-- Offers are global: every server derives the same three from the event's
-- startsAt (see TravellingMerchant.OffersFor), so no coordination is needed.
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local Inventory = require(Shared:WaitForChild("Inventory"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local PartVolume = require(Shared:WaitForChild("PartVolume"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))
local TravellingMerchant = require(Shared:WaitForChild("TravellingMerchant"))

local CurrencyService = require(script.Parent:WaitForChild("CurrencyService"))
local EventEligibility = require(script.Parent:WaitForChild("EventEligibility"))
local FoodInventoryService = require(script.Parent:WaitForChild("FoodInventoryService"))
local GrowSkipService = require(script.Parent:WaitForChild("GrowSkipService"))
local NotificationService = require(script.Parent:WaitForChild("NotificationService"))
local PetIncomeService = require(script.Parent:WaitForChild("PetIncomeService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(script.Parent:WaitForChild("PlayerReplicaService"))
local ReceiptService = require(script.Parent:WaitForChild("ReceiptService"))
local SeedPackShopService = require(script.Parent:WaitForChild("SeedPackShopService"))
local SeedTools = require(script.Parent:WaitForChild("SeedTools"))
local TelemetryService = require(script.Parent:WaitForChild("TelemetryService"))

local TravellingMerchantService = {}

local REQUEST_RATE_SECONDS = 0.35
-- Long enough to cover the Robux prompt round trip, short enough that an
-- abandoned prompt does not block the next attempt for the whole visit.
local RESERVATION_SECONDS = 300

local Kinds = TravellingMerchant.RewardKinds

local lastRequest = {}
local locks = {}
local started = false
local snapshotProfileState = nil
local isGameplayBlocked = nil

-- The live event record, or nil when the merchant is not here. This is the
-- authority on which offers exist: the client's offerId is only ever resolved
-- against activeRecord.startsAt.
local activeRecord = nil

local function userKey(player)
	return player and player.UserId or nil
end

local function int(value, fallback)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return fallback or 0
	end
	return math.floor(value)
end

local function isValidRequestId(value)
	return type(value) == "number" and value == math.floor(value) and value > 0
end

local function consumeRateLimit(player)
	local key = userKey(player)
	if key == nil then
		return false
	end
	local now = os.clock()
	local previous = lastRequest[key] or 0
	if now - previous < REQUEST_RATE_SECONDS then
		return false
	end
	lastRequest[key] = now
	return true
end

local function saveProfile(profile)
	local ok = pcall(function()
		profile:Save()
	end)
	return ok
end

-- Resolved lazily, and guarded: ProcessReceipt can fire before Start on a server
-- that boots mid-purchase, and Remotes.get asserts rather than returning nil. An
-- unavailable result remote must not be allowed to throw out of a receipt --
-- losing the cosmetic result event is survivable, losing the grant is not.
local resultRemote = nil
local function fireResult(player, requestId, success, code, extra)
	if not resultRemote then
		local ok, remote = pcall(Remotes.get, Remotes.Names.MerchantTradeResult)
		if not ok then
			return
		end
		resultRemote = remote
	end
	local payload = {
		requestId = requestId,
		success = success == true,
		code = code,
	}
	if type(extra) == "table" then
		for payloadKey, value in pairs(extra) do
			payload[payloadKey] = value
		end
	end
	resultRemote:FireClient(player, payload)
end

---------------------------------------------------------------------------
-- Presence
---------------------------------------------------------------------------

-- The rig is anchored at the root so the Motor6Ds still hold the body together
-- if an idle track is added later. Persistent streaming matters because the
-- carriage is a map POI: on Default, a client streaming in mid-visit can miss
-- it entirely and walk through an invisible shop volume.
local function prepareModels(folder)
	local npc = folder:FindFirstChild(TravellingMerchant.NpcName)
	if npc and npc:IsA("Model") then
		npc.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
		local root = npc:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			root.Anchored = true
		else
			warn("[TravellingMerchantService] " .. TravellingMerchant.NpcName .. " has no HumanoidRootPart; rig may fall")
		end
		local humanoid = npc:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			humanoid.WalkSpeed = 0
			humanoid.JumpPower = 0
		end
	else
		warn("[TravellingMerchantService] Missing " .. TravellingMerchant.NpcName .. " rig in the merchant template")
	end

	local carriage = folder:FindFirstChild(TravellingMerchant.CarriageName)
	if carriage and carriage:IsA("Model") then
		carriage.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	end
end

local function spawnMerchant(record)
	local map = TravellingMerchant.FindMapFolder()
	if not map then
		warn("[TravellingMerchantService] Missing Workspace.Map; merchant not spawned")
		return false
	end
	if TravellingMerchant.FindRuntimeFolder() then
		return false
	end
	local template = TravellingMerchant.FindTemplate()
	if not template then
		warn("[TravellingMerchantService] Missing ReplicatedStorage.Assets."
			.. TravellingMerchant.AssetsFolderName .. "." .. TravellingMerchant.TemplateName
			.. "; merchant not spawned")
		return false
	end

	local folder = template:Clone()
	prepareModels(folder)
	-- Stamped before parenting so no client can observe the carriage without
	-- the window it belongs to; the billboard countdown reads these directly.
	folder:SetAttribute(State.Merchant.StartsAt, record.startsAt)
	folder:SetAttribute(State.Merchant.EndsAt, record.endsAt)
	folder:SetAttribute(State.Merchant.InstanceId, tostring(record.instanceId))
	folder.Parent = map
	return true
end

local function despawnMerchant()
	local folder = TravellingMerchant.FindRuntimeFolder()
	if not folder then
		return false
	end
	folder:Destroy()
	return true
end

function TravellingMerchantService.StartMerchant(record)
	if not TravellingMerchant.Enabled then
		return
	end
	activeRecord = record
	spawnMerchant(record)
	print(string.format("[TravellingMerchantService] Merchant arrived (%s)", tostring(record and record.instanceId)))
end

function TravellingMerchantService.StopMerchant()
	activeRecord = nil
	despawnMerchant()
	print("[TravellingMerchantService] Merchant left")
end

function TravellingMerchantService.IsActive()
	return activeRecord ~= nil
end

-- Read-only view of the live record, for the dev command surface.
function TravellingMerchantService.ActiveRecord()
	return activeRecord
end

-- Toast fired preNoticeSeconds before arrival. Gated on eligibility for the same
-- reason the other events gate theirs: telling a player mid-tutorial to go visit
-- a merchant they are not allowed to trade with is worse than saying nothing.
function TravellingMerchantService.NotifyMerchantArriving()
	if not TravellingMerchant.Enabled then
		return
	end
	local config = GameEvents.GetEvent(GameEvents.Ids.Merchant) or {}
	local text = config.preNoticeText or "A travelling merchant is arriving..."
	local lifetime = math.max(tonumber(config.preNoticeSeconds) or 5, 0)
	for _, player in ipairs(Players:GetPlayers()) do
		if EventEligibility.IsEligible(player) then
			-- Notify rather than Info: only the raw payload carries a lifetime,
			-- and preserveTrailingPeriods keeps the trailing ellipsis.
			RuntimeGuard.Run("TravellingMerchantService.NotifyArriving", function()
				NotificationService.Notify(player, {
					text = text,
					lifetime = lifetime,
					preserveTrailingPeriods = true,
				})
			end)
		end
	end
end

---------------------------------------------------------------------------
-- Offers and claims
---------------------------------------------------------------------------

local function ensureMerchantData(profile)
	local data = profile.Data.TravellingMerchant
	if type(data) ~= "table" then
		data = { InstanceId = "", Claimed = {} }
		profile.Data.TravellingMerchant = data
	end
	if type(data.Claimed) ~= "table" then
		data.Claimed = {}
	end
	return data
end

-- Claims are scoped to a single visit. Rather than clearing them when the
-- merchant leaves (which would need every online profile touched, and would
-- miss offline players entirely), the visit's instanceId is stored alongside
-- them and a mismatch wipes them lazily on next use.
local function claimsForVisit(profile, instanceId)
	local data = ensureMerchantData(profile)
	if data.InstanceId ~= instanceId then
		data.InstanceId = instanceId
		data.Claimed = {}
	end
	return data
end

function TravellingMerchantService.CurrentOffers()
	if not activeRecord then
		return {}
	end
	return TravellingMerchant.OffersFor(activeRecord.startsAt)
end

---------------------------------------------------------------------------
-- Rewards
---------------------------------------------------------------------------

local function cashPayout(player, reward)
	local hourlyIncome = 0
	local ok, income = pcall(function()
		return PetIncomeService.Refresh(player)
	end)
	if ok then
		hourlyIncome = tonumber(income) or 0
	end
	return ShopBalance.CashPackPayout({
		HoursOfIncome = reward.hoursOfIncome,
		BaseReward = reward.baseReward,
	}, hourlyIncome)
end

-- Side-effect-free check that the reward could land right now, run BEFORE any
-- food is taken.
--
-- This exists because consuming is irreversible and granting is not guaranteed.
-- A grow skip on a plot with nothing growing legitimately refuses, and without
-- this the player would already have paid ten Plums for that refusal. Not a
-- guarantee -- state can still move between here and the grant -- but it turns
-- the common failures into a clean "trade refused, nothing taken".
local function canGrantReward(player, context, reward)
	local kind = reward.kind

	if kind == Kinds.GrowSkip then
		return GrowSkipService.CanApplyPlotTimeSkip(player, context.plot)
	end

	if kind == Kinds.Seed or kind == Kinds.SeedPack then
		-- Same ceiling the grant itself uses, so this check and ToolGrantService
		-- agree on what "full" means.
		local wanted = math.max(int(reward.amount, 1), 1)
		if Inventory.RemainingSlots(player, Inventory.HARD_MAX_ITEMS) < wanted then
			return false, "inventory-full"
		end
		return true, "ok"
	end

	if kind == Kinds.Cash then
		if cashPayout(player, reward) <= 0 then
			return false, "no-payout"
		end
		return true, "ok"
	end

	if kind == Kinds.DurianTicket then
		return true, "ok"
	end

	return false, "unknown-reward"
end

-- Grants one offer's reward. Returns ok, code, extra -- where extra carries any
-- payload the client needs (the seed pack reveal, the cash amount to toast).
--
-- Never partially grants: each branch either fully lands or reports a code, so
-- the caller can decide whether the player was charged.
local function grantReward(player, profile, context, reward)
	local kind = reward.kind

	if kind == Kinds.Seed then
		local prepared, code = SeedTools.PrepareGrant(reward.seedId, math.max(int(reward.amount, 1), 1))
		if not prepared then
			return false, code or "grant-failed", nil
		end
		local applied, applyCode = SeedTools.ApplyPrepared(player, profile, prepared, {
			-- Traded seeds go above the soft cap for the same reason bought
			-- packs do: the player has already paid, and refusing here would
			-- consume the items and hand back nothing.
			maxItems = Inventory.HARD_MAX_ITEMS,
			autoEquip = false,
		})
		if not applied then
			-- ApplyPrepared destroys the prepared tools itself on every failure
			-- path, so there is nothing left to clean up here.
			return false, applyCode or "grant-failed", nil
		end
		return true, "ok", { seedId = reward.seedId, displayName = Seeds.DisplayNameFor(reward.seedId) }
	end

	if kind == Kinds.SeedPack then
		local granted, code, revealPayload = SeedPackShopService.GrantPackRoll(
			player,
			profile,
			reward.packId,
			math.max(int(reward.amount, 1), 1),
			TravellingMerchant.RevealSourceSection
		)
		if not granted then
			return false, code or "grant-failed", nil
		end
		return true, "ok", { reveal = revealPayload }
	end

	if kind == Kinds.GrowSkip then
		local skip = ShopBalance.GrowSkipForSkipId(reward.skipId)
		if not skip then
			return false, "unknown-skip", nil
		end
		local amount = math.max(int(reward.amount, 1), 1)
		-- Multi-skip merchant rewards are claimed together. Applying their total
		-- duration once keeps the trade atomic while producing the same plot-time
		-- result as two or three simultaneous copies of the configured skip.
		local durationSeconds = int(skip.DurationSeconds, 0) * amount
		local _, code = GrowSkipService.ApplyFreePlotTimeSkip(player, context.plot, durationSeconds)
		if code ~= "ok" then
			-- "no-growth" means the player has nothing growing to skip. That is
			-- a real refusal, not a silent success: charging fruit for a skip
			-- that does nothing is worse than declining the trade.
			return false, code or "grant-failed", nil
		end
		return true, "ok", {
			skipId = skip.SkipId,
			displayName = skip.DisplayName,
			amount = amount,
			durationSeconds = durationSeconds,
		}
	end

	if kind == Kinds.DurianTicket then
		local amount = math.max(int(reward.amount, 1), 1)
		profile.Data.DurianTickets = int(profile.Data.DurianTickets, 0) + amount
		PlayerReplicaService.PublishDurianPack(player, profile)
		return true, "ok", { tickets = amount }
	end

	if kind == Kinds.Cash then
		local amount = cashPayout(player, reward)
		if amount <= 0 then
			return false, "no-payout", nil
		end
		CurrencyService.Add(player, profile, amount)
		return true, "ok", { cash = amount }
	end

	return false, "unknown-reward", nil
end

local function rewardSummary(reward, extra)
	if reward.kind == Kinds.Cash then
		return string.format("You received %s!", NumberFormatter.Currency(extra and extra.cash or 0))
	end
	if reward.kind == Kinds.DurianTicket then
		local amount = extra and extra.tickets or 1
		return string.format("You received %d Durian Ticket%s!", amount, amount == 1 and "" or "s")
	end
	if reward.kind == Kinds.GrowSkip then
		local amount = math.max(int(extra and extra.amount, 1), 1)
		local displayName = (extra and extra.displayName) or "Growth skip"
		if amount > 1 then
			return string.format("%dx %s applied to your plot!", amount, displayName)
		end
		return string.format("%s applied to your plot!", displayName)
	end
	if reward.kind == Kinds.Seed then
		return string.format("You received a %s!", (extra and extra.displayName) or "seed")
	end
	if reward.kind == Kinds.SeedPack then
		return "You received a Seed Pack!"
	end
	return "Trade complete!"
end

-- Player-facing text for every refusal. A trade that silently does nothing is
-- indistinguishable from a bug, so every code that can reach a player has a
-- line here.
local REJECT_MESSAGES = {
	["blocked"] = "Your inventory is still loading, try again in a moment",
	["onboarding"] = "Finish the tutorial to trade with the merchant",
	["offline-progress-pending"] = "Your offline progress is still being applied",
	["no-plot"] = "You need a plot to trade with the merchant",
	["profile-not-loaded"] = "Your data is still loading, try again in a moment",
	["gone"] = "The merchant has already left!",
	["too-far"] = "Step up to the merchant to trade!",
	["unknown-offer"] = "That offer is no longer available",
	["claimed"] = "You have already taken that trade",
	-- Deliberately generic and identical for every offer. The Trade button is
	-- never dimmed for a shortfall -- the player presses it and gets told -- so
	-- this is the whole feedback for that case.
	["not-enough"] = "Not enough items in your inventory!",
	["no-growth"] = "You have nothing growing to skip right now",
	["inventory-full"] = nil, -- ToolGrantService raises its own notification
	["no-payout"] = "Could not work out a cash reward, try again",
}

---------------------------------------------------------------------------
-- Skip reservations
---------------------------------------------------------------------------

local function clearReservation(profile)
	profile.Data.PendingMerchantReservation = nil
end

local function pendingReservation(profile, productId)
	local reservation = profile and profile.Data and profile.Data.PendingMerchantReservation
	if type(reservation) ~= "table" then
		return nil
	end
	if int(reservation.productId, 0) ~= int(productId, 0) then
		return nil
	end
	return reservation
end

local function reservationExpired(reservation)
	return os.time() > int(reservation.expiresAt, 0)
end

---------------------------------------------------------------------------
-- Shared validation
---------------------------------------------------------------------------

-- Everything a trade or a skip must be true of, in the order the plan fixed.
-- Returns context, code -- context carries the profile/plot from
-- EventEligibility plus the resolved offer, so callers do not re-look-up.
local function validateOffer(player, offerId, requireProximity)
	if type(isGameplayBlocked) == "function" and isGameplayBlocked(player) then
		return nil, "blocked"
	end

	local context, code = EventEligibility.Context(player)
	if not context then
		return nil, code or "not-eligible"
	end

	if not (TravellingMerchant.Enabled and activeRecord) then
		return nil, "gone"
	end

	local offer, slot = TravellingMerchant.OfferFor(activeRecord.startsAt, offerId)
	if not offer then
		return nil, "unknown-offer"
	end

	if requireProximity then
		local shopPart = TravellingMerchant.FindShopPart()
		if not (shopPart and PartVolume.ContainsPlayer(shopPart, player)) then
			return nil, "too-far"
		end
	end

	local data = claimsForVisit(context.profile, activeRecord.instanceId)
	if data.Claimed[offer.offerId] == true then
		return nil, "claimed"
	end

	context.offer = offer
	context.slot = slot
	context.merchantData = data
	return context, "ok"
end

---------------------------------------------------------------------------
-- Receipts (skip products)
---------------------------------------------------------------------------

function TravellingMerchantService.HandlesProductId(productId)
	return ShopBalance.MerchantSkipForProductId(productId) ~= nil
end

function TravellingMerchantService.ProcessReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	local profile = player and PlayerDataService.GetProfile(player)
	local skip = ShopBalance.MerchantSkipForProductId(receiptInfo.ProductId)
	local purchaseId = ReceiptService.Key(receiptInfo.PurchaseId)
	if not (player and profile and skip and purchaseId) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if ReceiptService.HasProcessed(profile, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local key = userKey(player)
	if not key or locks[key] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local reservation = pendingReservation(profile, receiptInfo.ProductId)

	-- Paid but ungrantable. The reward is gone either way, so mark the receipt
	-- processed and return PurchaseGranted: charging the player twice for
	-- something they cannot receive is the worse failure. Same contract as
	-- GrowSkipService.finishNoOp.
	local function finishNoOp(reason)
		clearReservation(profile)
		ReceiptService.MarkProcessed(profile, purchaseId)
		if not saveProfile(profile) then
			ReceiptService.ClearProcessed(profile, purchaseId)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		warn("[TravellingMerchantService] Skip purchase no-op: " .. tostring(reason))
		NotificationService.Error(player, "The merchant left before that trade could be completed")
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if not reservation then
		return finishNoOp("missing-reservation")
	end
	if reservationExpired(reservation) then
		return finishNoOp("reservation-expired")
	end

	-- Re-validate without the proximity check: the player legitimately walked
	-- away while the Robux prompt was up, and they have already paid.
	local context, code = validateOffer(player, reservation.offerId, false)
	if not context then
		if code == "claimed" then
			-- Already granted by a racing path; nothing more to do.
			return finishNoOp("already-claimed")
		end
		return finishNoOp(code or "not-eligible")
	end
	if context.offer.offerId ~= reservation.offerId then
		return finishNoOp("offer-changed")
	end

	locks[key] = true
	local granted = false
	local resultCode = "server-error"
	local extra = nil

	local ok, err = pcall(function()
		granted, resultCode, extra = grantReward(player, context.profile, context, context.offer.reward)
		if not granted then
			return
		end

		context.merchantData.Claimed[context.offer.offerId] = true
		clearReservation(context.profile)
		ReceiptService.MarkProcessed(context.profile, purchaseId)

		resultCode = "snapshot-failed"
		if type(snapshotProfileState) == "function"
			and snapshotProfileState(player, context.plot, context.profile) ~= true then
			ReceiptService.ClearProcessed(context.profile, purchaseId)
			granted = false
			return
		end

		resultCode = "save-failed"
		if not saveProfile(context.profile) then
			ReceiptService.ClearProcessed(context.profile, purchaseId)
			granted = false
			return
		end

		granted = true
		resultCode = "ok"
	end)
	locks[key] = nil

	if not ok then
		ReceiptService.ClearProcessed(profile, purchaseId)
		warn("[TravellingMerchantService] Skip receipt failed: " .. tostring(err))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if granted then
		PlayerReplicaService.PublishTravellingMerchant(player, context.profile)
		PlayerReplicaService.PublishInventories(player, context.profile)
		NotificationService.Success(player, rewardSummary(context.offer.reward, extra))
		fireResult(player, nil, true, "skipped", {
			offerId = context.offer.offerId,
			reveal = extra and extra.reveal or nil,
		})
		TelemetryService.Record("merchant_skip_granted", TelemetryService.ForPlayer(player, {
			offerId = context.offer.offerId,
			slot = context.slot,
			productId = receiptInfo.ProductId,
		}))
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- A grant that failed for a reason the player cannot fix (no growth to
	-- skip, inventory full) still leaves them charged, so it must not retry
	-- forever -- finishNoOp is the honest end state.
	if resultCode == "no-growth" or resultCode == "inventory-full" or resultCode == "no-payout" then
		return finishNoOp(resultCode)
	end

	warn("[TravellingMerchantService] Skip grant failed: " .. tostring(resultCode))
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------

function TravellingMerchantService.Start(config)
	if started then
		return
	end
	if not TravellingMerchant.Enabled then
		return
	end
	started = true
	config = type(config) == "table" and config or {}
	snapshotProfileState = config.snapshotProfileState
	isGameplayBlocked = config.isGameplayBlocked

	assert(type(snapshotProfileState) == "function", "TravellingMerchantService.Start requires snapshotProfileState")

	local requestRemote = Remotes.get(Remotes.Names.MerchantTradeRequest)

	local function reject(player, requestId, code, message)
		if message then
			NotificationService.Error(player, message)
		end
		TelemetryService.Record("merchant_trade_rejected", TelemetryService.ForPlayer(player, {
			reason = code,
		}))
		fireResult(player, requestId, false, code)
	end

	local function handleTrade(player, requestId, offerId)
		local context, code = validateOffer(player, offerId, true)
		if not context then
			reject(player, requestId, code, REJECT_MESSAGES[code])
			return
		end

		local offer = context.offer
		local request = offer.request
		local amount = math.max(int(request.amount, 1), 1)

		-- Checked before consuming so a short inventory costs the player
		-- nothing; ConsumeFoodId re-checks and is itself all-or-nothing.
		local held = FoodInventoryService.CountSpendable(player, request.foodId)
		if held < amount then
			reject(player, requestId, "not-enough", REJECT_MESSAGES["not-enough"])
			return
		end

		-- Also before consuming. A grow skip with nothing growing is a real
		-- refusal, and the player must not have paid for it.
		local grantable, grantableCode = canGrantReward(player, context, offer.reward)
		if not grantable then
			reject(player, requestId, grantableCode, REJECT_MESSAGES[grantableCode]
				or "Could not complete that trade")
			return
		end

		local key = userKey(player)
		if not key or locks[key] then
			reject(player, requestId, "busy")
			return
		end

		locks[key] = true
		local traded = false
		local resultCode = "server-error"
		local extra = nil

		local ok, err = pcall(function()
			-- canGrantReward above has already ruled out the failures we can
			-- see coming, so by here the grant is expected to succeed. It is
			-- still not guaranteed -- hence the loud warning below if it does
			-- not -- but the ordinary refusals never reach this point.
			local consumed, consumeCode = FoodInventoryService.ConsumeFoodId(player, request.foodId, amount)
			if not consumed then
				resultCode = consumeCode or "not-enough"
				return
			end

			traded, resultCode, extra = grantReward(player, context.profile, context, offer.reward)
			if not traded then
				-- The food is already gone and cannot be rebuilt faithfully
				-- (XP, mutations and scale are per-tool). Refunding the cash
				-- value is not a thing this game has, so the honest fallback is
				-- to surface the failure loudly and leave the offer unclaimed
				-- so the player can retry once the blocker clears.
				warn(string.format(
					"[TravellingMerchantService] Consumed %d %s but reward failed (%s) for %s",
					amount, request.foodId, tostring(resultCode), tostring(player)
				))
				return
			end

			context.merchantData.Claimed[offer.offerId] = true
			if type(snapshotProfileState) == "function" then
				snapshotProfileState(player, context.plot, context.profile)
			end
		end)
		locks[key] = nil

		if not ok then
			warn("[TravellingMerchantService] Trade failed: " .. tostring(err))
			reject(player, requestId, "server-error", "Something went wrong with that trade")
			return
		end

		if not traded then
			reject(player, requestId, resultCode, REJECT_MESSAGES[resultCode]
				or "Could not complete that trade")
			return
		end

		PlayerReplicaService.PublishTravellingMerchant(player, context.profile)
		PlayerReplicaService.PublishInventories(player, context.profile)
		NotificationService.Success(player, rewardSummary(offer.reward, extra))
		fireResult(player, requestId, true, "traded", {
			offerId = offer.offerId,
			reveal = extra and extra.reveal or nil,
		})
		TelemetryService.Record("merchant_trade_completed", TelemetryService.ForPlayer(player, {
			offerId = offer.offerId,
			slot = context.slot,
			rewardKind = offer.reward.kind,
		}))
	end

	-- Writes the reservation and hands back the product id; the client prompts.
	-- Saved before the prompt so a receipt that arrives after a server restart
	-- still finds something to honour.
	local function handleSkipRequest(player, requestId, offerId)
		local context, code = validateOffer(player, offerId, true)
		if not context then
			reject(player, requestId, code, REJECT_MESSAGES[code])
			return
		end

		local skip = ShopBalance.MerchantSkipForSlot(context.slot)
		local productId = skip and int(skip.DevProductId, 0) or 0
		if productId <= 0 then
			reject(player, requestId, "no-product", "That option is not available yet")
			return
		end

		local reservation = {
			offerId = context.offer.offerId,
			slot = context.slot,
			productId = productId,
			instanceId = activeRecord.instanceId,
			createdAt = os.time(),
			expiresAt = os.time() + RESERVATION_SECONDS,
		}
		context.profile.Data.PendingMerchantReservation = reservation
		if not saveProfile(context.profile) then
			clearReservation(context.profile)
			reject(player, requestId, "save-failed", "Could not start that purchase, try again")
			return
		end

		fireResult(player, requestId, true, "prompt", {
			offerId = context.offer.offerId,
			productId = productId,
			expiresAt = reservation.expiresAt,
		})
	end

	RuntimeGuard.Connect(requestRemote.OnServerEvent, "TravellingMerchantService.Request", function(player, requestId, offerId, action)
		if not isValidRequestId(requestId) then
			return
		end
		if type(offerId) ~= "string" or offerId == "" or #offerId > 64 then
			return
		end
		if not consumeRateLimit(player) then
			return
		end
		if action == "skip" then
			handleSkipRequest(player, requestId, offerId)
		else
			handleTrade(player, requestId, offerId)
		end
	end)

	RuntimeGuard.Connect(MarketplaceService.PromptProductPurchaseFinished, "TravellingMerchantService.PromptFinished", function(playerOrUserId, finishedProductId, wasPurchased)
		if wasPurchased == true then
			return
		end
		local userId = typeof(playerOrUserId) == "Instance" and playerOrUserId.UserId or playerOrUserId
		local player = Players:GetPlayerByUserId(userId)
		if not (player and ShopBalance.MerchantSkipForProductId(finishedProductId)) then
			return
		end
		local profile = PlayerDataService.GetProfile(player)
		if profile and pendingReservation(profile, finishedProductId) then
			clearReservation(profile)
			saveProfile(profile)
		end
	end)

	RuntimeGuard.Connect(Players.PlayerRemoving, "TravellingMerchantService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			locks[key] = nil
			lastRequest[key] = nil
		end
	end)
end

return TravellingMerchantService
