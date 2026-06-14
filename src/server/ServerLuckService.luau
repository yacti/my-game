local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Server = script.Parent
local NotificationService = require(Server:WaitForChild("NotificationService"))
local OfflineProgressService = require(Server:WaitForChild("OfflineProgressService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local ReceiptService = require(Server:WaitForChild("ReceiptService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))

local ServerLuckService = {}

local PURCHASE_INTENT_SECONDS = 60
local REQUEST_RATE_SECONDS = 0.5
local INTENT_FIELD = "ServerLuckPurchaseIntent"

local started = false
local locks = {}
local lastRequest = {}
local expireToken = 0

local baseMultiplier = ShopBalance.ServerLuck.BaseMultiplier
local maxMultiplier = ShopBalance.ServerLuck.MaxMultiplier
local currentMultiplier = baseMultiplier
local endsAt = 0

local boostedRemote = Remotes.get(Remotes.Names.ServerLuckBoosted)
local purchaseRequestRemote = Remotes.get(Remotes.Names.ServerLuckPurchaseRequest)
local purchaseResultRemote = Remotes.get(Remotes.Names.ServerLuckPurchaseResult)

local function userKey(player)
	return player and player.UserId or nil
end

local function now()
	return Workspace:GetServerTimeNow()
end

local function saveProfile(profile)
	local ok = pcall(function()
		profile:Save()
	end)
	return ok
end

local function int(value, minimum)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return minimum or 0
	end
	return math.max(math.floor(value), minimum or 0)
end

local function productId(value)
	return int(value, 0)
end

local function unixNow()
	return os.time()
end

local function publish()
	ReplicatedStorage:SetAttribute(State.ServerLuck.Multiplier, currentMultiplier)
	ReplicatedStorage:SetAttribute(State.ServerLuck.EndsAt, endsAt)
end

local function expireIfNeeded()
	if endsAt > 0 and now() >= endsAt then
		currentMultiplier = baseMultiplier
		endsAt = 0
		publish()
	end
end

local function scheduleExpiration()
	expireToken += 1
	local token = expireToken
	local delaySeconds = math.max(endsAt - now(), 0)
	if delaySeconds <= 0 then
		expireIfNeeded()
		return
	end

	task.delay(delaySeconds + 0.1, function()
		if token ~= expireToken then
			return
		end
		expireIfNeeded()
	end)
end

local function sendPurchaseResult(player, requestId, success, code, payload)
	local result = type(payload) == "table" and payload or {}
	result.requestId = requestId
	result.success = success == true
	result.code = code
	purchaseResultRemote:FireClient(player, result)
end

local function activeStep()
	expireIfNeeded()
	return ShopBalance.ServerLuckStepForCurrentMultiplier(currentMultiplier)
end

local function createIntent(step)
	local issuedAt = unixNow()
	return {
		productId = productId(step and step.DevProductId),
		fromMultiplier = currentMultiplier,
		toMultiplier = int(step and step.ToMultiplier, baseMultiplier),
		issuedAt = issuedAt,
		expiresAt = issuedAt + PURCHASE_INTENT_SECONDS,
	}
end

local function validIntentForProduct(profile, productIdValue)
	local intent = profile and profile.Data and profile.Data[INTENT_FIELD]
	if type(intent) ~= "table" then
		return nil
	end
	if productId(intent.productId) ~= productId(productIdValue) then
		return nil
	end
	if int(intent.expiresAt, 0) < unixNow() then
		return nil
	end
	return intent
end

local function clearIntent(profile)
	if profile and profile.Data then
		profile.Data[INTENT_FIELD] = nil
	end
end

local function multiplierText(multiplier)
	return tostring(math.max(math.floor(tonumber(multiplier) or baseMultiplier), baseMultiplier)) .. "x"
end

local function notifyBoost(purchaser, multiplier)
	local displayName = purchaser and purchaser.DisplayName or "A player"
	local message = string.format("%s boosted Server Luck to %s!", displayName, multiplierText(multiplier))
	for _, player in ipairs(Players:GetPlayers()) do
		NotificationService.Success(player, message)
	end
end

local function fireConfetti(purchaser, multiplier)
	RuntimeGuard.Run("ServerLuckService.FireBoosted", function()
		boostedRemote:FireAllClients({
			boosterUserId = purchaser and purchaser.UserId or nil,
			boosterName = purchaser and purchaser.DisplayName or nil,
			multiplier = multiplier,
			endsAt = endsAt,
		})
	end)
end

local function applyBoost(purchaser, step)
	expireIfNeeded()

	local targetMultiplier = math.min(tonumber(step and step.ToMultiplier) or baseMultiplier, maxMultiplier)
	currentMultiplier = math.clamp(math.max(currentMultiplier, targetMultiplier), baseMultiplier, maxMultiplier)
	endsAt = math.max(now(), endsAt) + ShopBalance.ServerLuck.DurationSeconds
	publish()
	scheduleExpiration()

	notifyBoost(purchaser, currentMultiplier)
	fireConfetti(purchaser, currentMultiplier)
end

function ServerLuckService.CurrentMultiplier()
	expireIfNeeded()
	return currentMultiplier
end

function ServerLuckService.HandlesProductId(productId)
	return ShopBalance.ServerLuckStepForProductId(productId) ~= nil
end

local function onPurchaseRequest(player, requestId)
	if type(requestId) ~= "number" then
		return
	end

	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		sendPurchaseResult(player, requestId, false, "profile-not-ready")
		return
	end
	if OfflineProgressService.IsPending(player) then
		sendPurchaseResult(player, requestId, false, "offline-progress")
		return
	end

	local key = userKey(player)
	if not key then
		sendPurchaseResult(player, requestId, false, "invalid-player")
		return
	end
	local nowSeconds = now()
	if lastRequest[key] and nowSeconds - lastRequest[key] < REQUEST_RATE_SECONDS then
		sendPurchaseResult(player, requestId, false, "rate-limited")
		return
	end
	lastRequest[key] = nowSeconds
	if locks[key] then
		sendPurchaseResult(player, requestId, false, "busy")
		return
	end

	locks[key] = true
	local intent = nil
	local saved = false
	local ok, err = pcall(function()
		local step = activeStep()
		if not step then
			return
		end
		intent = createIntent(step)
		profile.Data[INTENT_FIELD] = intent
		saved = saveProfile(profile)
		if not saved then
			clearIntent(profile)
		end
	end)
	locks[key] = nil

	if not ok then
		clearIntent(profile)
		warn("[ServerLuckService] Purchase intent failed: " .. tostring(err))
		sendPurchaseResult(player, requestId, false, "server-error")
		return
	end
	if not (saved and intent) then
		sendPurchaseResult(player, requestId, false, "save-failed")
		return
	end

	sendPurchaseResult(player, requestId, true, "ok", {
		productId = intent.productId,
		currentMultiplier = currentMultiplier,
		nextMultiplier = intent.toMultiplier,
		expiresAt = intent.expiresAt,
	})
end

function ServerLuckService.ProcessReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	local profile = player and PlayerDataService.GetProfile(player)
	local step = ShopBalance.ServerLuckStepForProductId(receiptInfo.ProductId)
	local purchaseId = ReceiptService.Key(receiptInfo.PurchaseId)
	if not (player and profile and step and purchaseId) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if ReceiptService.HasProcessed(profile, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if OfflineProgressService.IsPending(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local key = userKey(player)
	if not key or locks[key] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	locks[key] = true
	local saved = false
	local grantStep = nil
	local oldIntent = profile.Data[INTENT_FIELD]
	local resultCode = "invalid-product"
	local ok, err = pcall(function()
		local intent = validIntentForProduct(profile, receiptInfo.ProductId)
		if intent then
			local intendedMultiplier = int(intent.toMultiplier, baseMultiplier)
			if currentMultiplier > intendedMultiplier then
				resultCode = "stage-advanced"
				return
			end
			grantStep = {
				ToMultiplier = intendedMultiplier,
			}
		else
			local currentStep = activeStep()
			if productId(currentStep and currentStep.DevProductId) ~= productId(receiptInfo.ProductId) then
				return
			end
			grantStep = currentStep
		end
		resultCode = "save-failed"
		clearIntent(profile)
		ReceiptService.MarkProcessed(profile, purchaseId)
		saved = saveProfile(profile)
		if not saved then
			ReceiptService.ClearProcessed(profile, purchaseId)
			profile.Data[INTENT_FIELD] = oldIntent
		end
	end)
	locks[key] = nil

	if not ok then
		ReceiptService.ClearProcessed(profile, purchaseId)
		profile.Data[INTENT_FIELD] = oldIntent
		warn("[ServerLuckService] Receipt processing failed: " .. tostring(err))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not (saved and grantStep) then
		if resultCode ~= "invalid-product" then
			warn("[ServerLuckService] Receipt failed: " .. tostring(resultCode))
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	applyBoost(player, grantStep)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function ServerLuckService.Start()
	if started then
		return
	end
	started = true

	currentMultiplier = baseMultiplier
	endsAt = 0
	publish()

	RuntimeGuard.Connect(Players.PlayerRemoving, "ServerLuckService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			locks[key] = nil
			lastRequest[key] = nil
		end
	end)
	RuntimeGuard.Connect(purchaseRequestRemote.OnServerEvent, "ServerLuckService.PurchaseRequest", onPurchaseRequest)
end

return ServerLuckService
