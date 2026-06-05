local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Server = script.Parent
local CosmeticTools = require(Server:WaitForChild("CosmeticTools"))
local CurrencyService = require(Server:WaitForChild("CurrencyService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local ReceiptService = require(Server:WaitForChild("ReceiptService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticShopBalance = require(Shared:WaitForChild("CosmeticShopBalance"))
local Cosmetics = require(Shared:WaitForChild("Cosmetics"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local CosmeticShopService = {}

local REQUEST_RATE_SECONDS = 0.35

local started = false
local locks = {}
local lastRequestAt = {}

local resultRemote = Remotes.get(Remotes.Names.CosmeticShopPurchaseResult)

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

local function rootPart(player)
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root or nil
end

local function nearShop(player)
	local map = Workspace:FindFirstChild("Map")
	local shopParts = map and map:FindFirstChild("ShopParts")
	local part = shopParts and shopParts:FindFirstChild("CosmeticShop")
	local root = rootPart(player)
	if not (part and part:IsA("BasePart") and root) then
		return false
	end

	local localPosition = part.CFrame:PointToObjectSpace(root.Position)
	local half = part.Size * 0.5
	return math.abs(localPosition.X) <= half.X
		and math.abs(localPosition.Y) <= half.Y
		and math.abs(localPosition.Z) <= half.Z
end

local function sendResult(player, requestId, itemId, success, code)
	resultRemote:FireClient(player, {
		requestId = requestId,
		itemId = itemId,
		success = success == true,
		code = code,
	})
end

local function takeRateLimit(player)
	local key = userKey(player)
	if not key then return false end
	local now = os.clock()
	if now - (lastRequestAt[key] or 0) < REQUEST_RATE_SECONDS then
		return false
	end
	lastRequestAt[key] = now
	return true
end

local function validateItem(item)
	if not item then
		return false, "invalid-item"
	end
	if type(item.ItemID) ~= "string" or item.ItemID == "" then
		return false, "unsupported-item"
	end
	if not Cosmetics.GetTemplate(item.ItemID) then
		return false, "no-template"
	end
	return true, "ok"
end

local function displayName(item)
	return Cosmetics.DisplayNameFor(item and item.ItemID) or item and item.ItemID or "Item"
end

local function prepare(item)
	return CosmeticTools.PrepareGrant(item.ItemID, 1)
end

local function rollbackPrepared(profile, prepared)
	if type(prepared) ~= "table" then return end
	local cosmeticId = prepared.cosmeticId
	local amount = int(prepared.amount)
	if type(cosmeticId) == "string" and amount > 0 then
		local inventory = profile.Data.CosmeticInventory or {}
		profile.Data.CosmeticInventory = inventory
		inventory[cosmeticId] = math.max(int(inventory[cosmeticId]) - amount, 0)
		if inventory[cosmeticId] <= 0 then
			inventory[cosmeticId] = nil
		end
	end
	CosmeticTools.DestroyPrepared(prepared)
end

local function saveProfile(profile)
	local ok = pcall(function()
		profile:Save()
	end)
	return ok
end

local function grantPrepared(player, profile, item)
	local prepared, code = prepare(item)
	if not prepared then
		return false, code or "grant-failed"
	end

	local granted, grantCode = CosmeticTools.ApplyPrepared(player, profile, prepared)
	if not granted then
		CosmeticTools.DestroyPrepared(prepared)
		return false, grantCode or "grant-failed"
	end
	return true, "ok", prepared
end

function CosmeticShopService.HandlesProductId(productId)
	return CosmeticShopBalance.ForProductId(productId) ~= nil
end

function CosmeticShopService.PurchaseWithCurrency(player, requestId, itemId)
	local key = userKey(player)
	local profile = PlayerDataService.GetProfile(player)
	if not key or type(itemId) ~= "string" then
		return false, "invalid-request"
	end
	if not takeRateLimit(player) then
		sendResult(player, requestId, itemId, false, "rate-limited")
		return false, "rate-limited"
	end
	if locks[key] then
		sendResult(player, requestId, itemId, false, "busy")
		return false, "busy"
	end
	if not profile then
		sendResult(player, requestId, itemId, false, "no-profile")
		return false, "no-profile"
	end
	if not nearShop(player) then
		sendResult(player, requestId, itemId, false, "too-far")
		NotificationService.Error(player, "Move closer to the Cosmetic Shop.")
		return false, "too-far"
	end

	local item = CosmeticShopBalance.Get(itemId)
	local valid, code = validateItem(item)
	if not valid then
		sendResult(player, requestId, itemId, false, code)
		return false, code
	end

	locks[key] = true
	local price = CosmeticShopBalance.Price(item)
	local spentAmount = 0
	local ok, codeOrError = pcall(function()
		local spent, spendCode = CurrencyService.TrySpend(player, profile, price, true)
		if not spent then
			return spendCode or "insufficient-currency"
		end
		spentAmount = price

		local granted, grantCode = grantPrepared(player, profile, item)
		if not granted then
			CurrencyService.Add(player, profile, price, true)
			spentAmount = 0
			return grantCode or "grant-failed"
		end
		spentAmount = 0
		return "ok"
	end)
	locks[key] = nil

	local resultCode = ok and codeOrError or "server-error"
	if not ok and spentAmount > 0 then
		CurrencyService.Add(player, profile, spentAmount, true)
	end
	PlayerReplicaService.PublishProfile(player, profile)
	if resultCode == "ok" then
		NotificationService.Success(player, string.format("Purchased %s!", displayName(item)))
		sendResult(player, requestId, itemId, true, "ok")
		return true, "ok"
	end

	if resultCode == "insufficient-currency" then
		NotificationService.Error(player, "Not enough currency.")
	else
		NotificationService.Error(player, "Could not buy this cosmetic.")
	end
	sendResult(player, requestId, itemId, false, resultCode)
	return false, resultCode
end

function CosmeticShopService.ProcessReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	local profile = player and PlayerDataService.GetProfile(player)
	local item = CosmeticShopBalance.ForProductId(receiptInfo.ProductId)
	local purchaseId = ReceiptService.Key(receiptInfo.PurchaseId)
	if not (player and profile and item and purchaseId) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if ReceiptService.HasProcessed(profile, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if not validateItem(item) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local key = userKey(player)
	if not key or locks[key] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	locks[key] = true
	local granted, code, prepared = grantPrepared(player, profile, item)
	if granted then
		ReceiptService.MarkProcessed(profile, purchaseId)
		if not saveProfile(profile) then
			ReceiptService.ClearProcessed(profile, purchaseId)
			rollbackPrepared(profile, prepared)
			granted = false
			code = "save-failed"
		end
	end
	locks[key] = nil

	PlayerReplicaService.PublishProfile(player, profile)
	if granted then
		NotificationService.Success(player, string.format("Purchased %s!", displayName(item)))
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	warn("[CosmeticShopService] Receipt grant failed: " .. tostring(code))
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function CosmeticShopService.Start()
	if started then return end
	started = true

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.CosmeticShopPurchaseRequest).OnServerEvent, "CosmeticShopService.Purchase", function(player, requestId, itemId)
		CosmeticShopService.PurchaseWithCurrency(player, requestId, itemId)
	end)

	RuntimeGuard.Connect(Players.PlayerRemoving, "CosmeticShopService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			locks[key] = nil
			lastRequestAt[key] = nil
		end
	end)
end

return CosmeticShopService
