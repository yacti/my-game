local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local Cosmetics = require(Shared:WaitForChild("Cosmetics"))
local Food = require(Shared:WaitForChild("Food"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Rarities = require(Shared:WaitForChild("Rarities"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local State = require(Shared:WaitForChild("State"))

local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))

local ItemAddedDisplayController = {}

local HUD_NAME = "HUD"
local FRAME_NAME = "ItemAddedFrame"
local ITEM_TEMPLATE_NAME = "item"
local HUD_WAIT_SECONDS = 10
local FOOD_TOOL_ATTRIBUTE_RETRIES = 12
local FOOD_TOOL_ATTRIBUTE_RETRY_SECONDS = 0.08
local DISPLAY_SECONDS = 3
local MAX_VISIBLE_ITEMS = 4

local SHOW_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)
local HIDE_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)

local player = Players.LocalPlayer
local started = false
local warned = {}
local displayMain = nil
local itemTemplate = nil
local characterChildAdded = nil
local foodSuppressionReady = false
local foodSuppressionById = {}
local seenFoodTools = {}
local previousCountMaps = {}
local activeDisplays = {}
local activeDisplayOrder = {}
local displaySequence = 0
local feedTemplateByType = nil

local function warnOnce(key, message)
	if warned[key] then
		return
	end
	warn(message)
	warned[key] = true
end

local function countOf(value)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.max(math.floor(value), 0)
end

local function copyCountMap(value)
	local result = {}
	if type(value) ~= "table" then
		return result
	end
	for id, count in pairs(value) do
		if type(id) == "string" then
			local normalized = countOf(count)
			if normalized > 0 then
				result[id] = normalized
			end
		end
	end
	return result
end

local function formatCount(baseText, amount)
	amount = countOf(amount)
	if amount > 1 then
		return string.format("%s (%s)", baseText, NumberFormatter.Integer(amount))
	end
	return baseText
end

local function colorForRarity(rarity)
	if type(rarity) ~= "string" or rarity == "" then
		return nil
	end
	return Rarities.ColorFor(rarity, os.clock())
end

local function applyColor(label, color)
	if not color then
		return
	end
	label.TextColor3 = color
	local gradient = label:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Color = ColorSequence.new(color)
	end
end

local function disconnectRarity(entry)
	if entry and entry.rarityConnection then
		entry.rarityConnection:Disconnect()
		entry.rarityConnection = nil
	end
end

local function applyRarity(entry, rarity, fallbackColor)
	if not (entry and entry.label) then
		return
	end
	disconnectRarity(entry)

	local definition = type(rarity) == "string" and Rarities.Get(rarity) or nil
	if not definition then
		applyColor(entry.label, fallbackColor)
		return
	end

	local function refresh()
		if not (entry.label and entry.label.Parent) then
			disconnectRarity(entry)
			return
		end
		applyColor(entry.label, Rarities.ColorFor(rarity, os.clock()))
	end

	refresh()
	if definition.Animated then
		entry.rarityConnection = RuntimeGuard.Connect(RunService.RenderStepped, "ItemAddedDisplay.RarityRender", refresh)
	end
end

local function scaleUDim2(value, scale)
	return UDim2.new(
		value.X.Scale * scale,
		math.floor(value.X.Offset * scale),
		value.Y.Scale * scale,
		math.floor(value.Y.Offset * scale)
	)
end

local function strokeFor(label)
	local stroke = label:FindFirstChildOfClass("UIStroke")
	return stroke
end

local function removeFromDisplayOrder(entry)
	for index, current in ipairs(activeDisplayOrder) do
		if current == entry then
			table.remove(activeDisplayOrder, index)
			break
		end
	end
end

local function forgetDisplay(key, entry)
	if key ~= nil and activeDisplays[key] == entry then
		activeDisplays[key] = nil
	end
end

local function destroyDisplay(key, entry)
	entry.removing = true
	forgetDisplay(key, entry)
	removeFromDisplayOrder(entry)
	disconnectRarity(entry)

	local label = entry.label
	if label and label.Parent then
		label:Destroy()
	end
end

local function pruneDisplayOrder()
	local index = 1
	while index <= #activeDisplayOrder do
		local entry = activeDisplayOrder[index]
		if not (entry and entry.label and entry.label.Parent) then
			table.remove(activeDisplayOrder, index)
		else
			index += 1
		end
	end
end

local function trimDisplaysToMaxVisible(limit)
	pruneDisplayOrder()
	while #activeDisplayOrder > limit do
		local oldest = activeDisplayOrder[1]
		if not oldest then
			return
		end
		destroyDisplay(oldest.key, oldest)
	end
end

local function fadeOutDisplay(key, entry)
	if entry.removing then
		return
	end
	entry.removing = true
	forgetDisplay(key, entry)

	local label = entry.label
	if not (label and label.Parent) then
		removeFromDisplayOrder(entry)
		return
	end
	disconnectRarity(entry)

	local textTween = TweenService:Create(label, HIDE_TWEEN, {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	local stroke = strokeFor(label)
	local strokeTween = stroke and TweenService:Create(stroke, HIDE_TWEEN, {
		Transparency = 1,
	}) or nil

	textTween:Play()
	if strokeTween then
		strokeTween:Play()
	end

	textTween.Completed:Connect(function()
		if label.Parent then
			label:Destroy()
		end
		removeFromDisplayOrder(entry)
	end)
end

local function scheduleRemoval(key, entry)
	local token = entry.token
	task.delay(DISPLAY_SECONDS, function()
		RuntimeGuard.Run("ItemAddedDisplay.RemoveDelayed", function()
			if activeDisplays[key] == entry and entry.token == token then
				fadeOutDisplay(key, entry)
			end
		end)
	end)
end

local function showDisplay(key, baseText, amount, color, rarity)
	amount = countOf(amount)
	if amount <= 0 then
		return
	end
	if not (displayMain and itemTemplate) then
		return
	end

	local existing = activeDisplays[key]
	if existing and existing.label and existing.label.Parent and not existing.removing then
		existing.amount += amount
		existing.baseText = baseText
		existing.token += 1
		existing.label.Text = formatCount(baseText, existing.amount)
		applyRarity(existing, rarity, color)
		scheduleRemoval(key, existing)
		return
	end

	trimDisplaysToMaxVisible(MAX_VISIBLE_ITEMS - 1)

	local label = itemTemplate:Clone()
	label.Name = "ItemAdded"
	label.Visible = true
	label.Text = formatCount(baseText, amount)
	label.TextTransparency = 1
	label.TextStrokeTransparency = 1
	displaySequence += 1
	label.LayoutOrder = displaySequence

	local originalSize = label.Size
	label.Size = scaleUDim2(originalSize, 0.7)
	local stroke = strokeFor(label)
	local targetStrokeTransparency = stroke and stroke.Transparency or nil
	if stroke then
		stroke.Transparency = 1
	end
	label.Parent = displayMain

	local entry = {
		amount = amount,
		baseText = baseText,
		key = key,
		label = label,
		rarityConnection = nil,
		removing = false,
		token = 1,
	}
	activeDisplays[key] = entry
	table.insert(activeDisplayOrder, entry)
	applyRarity(entry, rarity, color)

	TweenService:Create(label, SHOW_TWEEN, {
		Size = originalSize,
		TextTransparency = 0,
		TextStrokeTransparency = 0,
	}):Play()
	if stroke and targetStrokeTransparency then
		TweenService:Create(stroke, SHOW_TWEEN, {
			Transparency = targetStrokeTransparency,
		}):Play()
	end

	scheduleRemoval(key, entry)
end

-- The display surface is the Studio-authored HUD frame (HUD has
-- ResetOnSpawn=false, so one bind survives respawns), mirroring how
-- Notifications.luau attaches to its HUD container.
local function attachDisplay()
	local playerGui = player:WaitForChild("PlayerGui")
	local hud = playerGui:WaitForChild(HUD_NAME, HUD_WAIT_SECONDS)
	local frame = hud and hud:FindFirstChild(FRAME_NAME, true)
	local item = frame and frame:FindFirstChild(ITEM_TEMPLATE_NAME)
	if not (frame and frame:IsA("GuiObject") and item and item:IsA("TextLabel")) then
		warnOnce(
			"missing-frame",
			string.format("[ItemAddedDisplayController] Missing HUD.%s with %q TextLabel; item-added display disabled", FRAME_NAME, ITEM_TEMPLATE_NAME)
		)
		return
	end

	item.Visible = false
	displayMain = frame
	itemTemplate = item
end

local function buildFeedIndex()
	local result = {}
	local root = Assets.Find(Assets.Names.FeedMachines)
	if not root then
		return result
	end
	for _, instance in ipairs(root:GetDescendants()) do
		if instance:IsA("BasePart") or instance:IsA("Model") then
			local feedType = instance:GetAttribute(State.Feed.Type)
			if type(feedType) == "string" and feedType ~= "" and not result[feedType] then
				result[feedType] = instance
			end
		end
	end
	return result
end

local function feedTemplateFor(feedType)
	if not feedTemplateByType then
		feedTemplateByType = buildFeedIndex()
	end
	return feedTemplateByType[feedType]
end

local function displayNameForFood(foodId)
	local producerFeedType, sourceFoodId = Food.ParseJamFoodId(foodId)
	if producerFeedType and sourceFoodId then
		local sourceTemplate = Food.GetTemplate(sourceFoodId)
		return (sourceTemplate and sourceTemplate.Name or sourceFoodId) .. " Jam"
	end
	local foodTemplate = Food.GetTemplate(foodId)
	return foodTemplate and foodTemplate.Name or foodId
end

local function foodDisplayInfo(foodId, xp)
	local name = displayNameForFood(foodId)
	local xpText = NumberFormatter.XP(xp, "xp")
	local rarity = Food.RarityFor(foodId)
	return string.format("%s %s", name, xpText), colorForRarity(rarity), rarity
end

local function seedDisplayInfo(seedId)
	local rarity = Seeds.RarityFor(seedId)
	return Seeds.DisplayNameFor(seedId), colorForRarity(rarity)
end

local function feedDisplayInfo(feedType)
	local feedTemplate = feedTemplateFor(feedType)
	local rarity = feedTemplate and feedTemplate:GetAttribute(State.Feed.Rarity) or nil
	return feedTemplate and feedTemplate.Name or feedType, colorForRarity(rarity)
end

local function cosmeticDisplayInfo(cosmeticId)
	local rarity = Cosmetics.RarityFor(cosmeticId)
	return Cosmetics.DisplayNameFor(cosmeticId), colorForRarity(rarity)
end

local function displayNonFood(category, itemId, amount)
	local baseText, color
	if category == "seed" then
		baseText, color = seedDisplayInfo(itemId)
	elseif category == "feed" then
		baseText, color = feedDisplayInfo(itemId)
	elseif category == "cosmetic" then
		baseText, color = cosmeticDisplayInfo(itemId)
	else
		return
	end
	showDisplay(category .. ":" .. itemId, baseText, amount, color)
end

local function observeCountMap(fieldName, category)
	PlayerStateStore.Observe(fieldName, function(newValue)
		local nextCounts = copyCountMap(newValue)
		local previousCounts = previousCountMaps[fieldName]
		if previousCounts == nil then
			previousCountMaps[fieldName] = nextCounts
			return
		end

		for itemId, count in pairs(nextCounts) do
			local delta = count - (previousCounts[itemId] or 0)
			if delta > 0 then
				displayNonFood(category, itemId, delta)
			end
		end
		previousCountMaps[fieldName] = nextCounts
	end)
end

local function foodToolKey(tool)
	local guid = tool:GetAttribute(State.Tool.Guid)
	if type(guid) == "string" and guid ~= "" then
		return "guid:" .. guid
	end
	return tool
end

local function shouldSuppressFood(foodId)
	local remaining = foodSuppressionById[foodId]
	if type(remaining) == "number" and remaining > 0 then
		foodSuppressionById[foodId] = remaining - 1
		return true
	end
	return false
end

local function tryProcessFoodTool(tool, retriesRemaining)
	if not (tool and tool:IsA("Tool") and tool.Parent) then
		return
	end
	if not foodSuppressionReady then
		return
	end

	local foodId = Food.IdOf(tool)
	local xp = Food.XPOf(tool)
	if not (type(foodId) == "string" and foodId ~= "" and type(xp) == "number") then
		if retriesRemaining > 0 then
			task.delay(FOOD_TOOL_ATTRIBUTE_RETRY_SECONDS, function()
				RuntimeGuard.Run("ItemAddedDisplay.RetryFoodTool", tryProcessFoodTool, tool, retriesRemaining - 1)
			end)
		end
		return
	end

	local key = foodToolKey(tool)
	if key == tool and retriesRemaining > 0 then
		task.delay(FOOD_TOOL_ATTRIBUTE_RETRY_SECONDS, function()
			RuntimeGuard.Run("ItemAddedDisplay.RetryFoodToolGuid", tryProcessFoodTool, tool, retriesRemaining - 1)
		end)
		return
	end
	if seenFoodTools[key] then
		return
	end
	seenFoodTools[key] = true
	-- Entries must survive Backpack<->Character moves but not the tool itself,
	-- or the set grows by one key for every food ever picked up.
	RuntimeGuard.Connect(tool.Destroying, "ItemAddedDisplay.FoodToolDestroying", function()
		seenFoodTools[key] = nil
	end)

	if shouldSuppressFood(foodId) then
		return
	end

	local baseText, color, rarity = foodDisplayInfo(foodId, xp)
	local displayXP = math.max(math.floor(xp), 0)
	showDisplay("food:" .. foodId .. ":" .. tostring(displayXP), baseText, 1, color, rarity)
end

local function processFoodTool(tool)
	if not (tool and tool:IsA("Tool")) then
		return
	end
	if seenFoodTools[foodToolKey(tool)] then
		return
	end
	RuntimeGuard.Spawn("ItemAddedDisplay.ProcessFoodTool", tryProcessFoodTool, tool, FOOD_TOOL_ATTRIBUTE_RETRIES)
end

local function scanFoodTools()
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, child in ipairs(backpack:GetChildren()) do
			processFoodTool(child)
		end
	end
	local character = player.Character
	if character then
		for _, child in ipairs(character:GetChildren()) do
			processFoodTool(child)
		end
	end
end

local function initializeFoodSuppression(foodInventory)
	if foodSuppressionReady then
		return
	end
	foodSuppressionById = copyCountMap(foodInventory)
	foodSuppressionReady = true
	scanFoodTools()
end

local function watchCharacter(character)
	if characterChildAdded then
		characterChildAdded:Disconnect()
		characterChildAdded = nil
	end
	if not character then
		return
	end
	for _, child in ipairs(character:GetChildren()) do
		processFoodTool(child)
	end
	characterChildAdded = RuntimeGuard.Connect(character.ChildAdded, "ItemAddedDisplay.CharacterChildAdded", processFoodTool)
end

function ItemAddedDisplayController.start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Spawn("ItemAddedDisplay.AttachDisplay", attachDisplay)

	RuntimeGuard.Connect(player.CharacterAdded, "ItemAddedDisplay.CharacterAdded", watchCharacter)
	RuntimeGuard.Run("ItemAddedDisplay.InitialCharacter", watchCharacter, player.Character)

	local backpack = player:WaitForChild("Backpack")
	RuntimeGuard.Connect(backpack.ChildAdded, "ItemAddedDisplay.BackpackChildAdded", processFoodTool)

	PlayerStateStore.Observe(PlayerStateStore.Fields.FoodInventory, initializeFoodSuppression)
	observeCountMap(PlayerStateStore.Fields.SeedInventory, "seed")
	observeCountMap(PlayerStateStore.Fields.FeedInventory, "feed")
	observeCountMap(PlayerStateStore.Fields.CosmeticInventory, "cosmetic")
end

return ItemAddedDisplayController
