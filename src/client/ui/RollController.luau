local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Rarities = require(Shared:WaitForChild("Rarities"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local RollChances = require(Shared:WaitForChild("RollChances"))
local RollConfig = require(Shared:WaitForChild("RollConfig"))
local RollRewards = require(Shared:WaitForChild("RollRewards"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local BillboardGuiTemplates = require(script.Parent:WaitForChild("BillboardGuiTemplates"))
local LocalPrompts = require(script.Parent:WaitForChild("LocalPrompts"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local RollController = {}

local CRATE_START_HEIGHT = RollConfig.Crate.StartHeight
local CRATE_FALL_DURATION = RollConfig.Crate.FallDuration
local CRATE_SWAY_AMPLITUDE = RollConfig.Crate.SwayAmplitude
local CRATE_TILT_DEGREES = RollConfig.Crate.TiltDegrees
local IMPACT_CHUNK_COUNT = RollConfig.Crate.ImpactChunkCount
local IMPACT_CHUNK_SIZE = RollConfig.Crate.ImpactChunkSize
local IMPACT_CHUNK_LIFETIME = RollConfig.Crate.ImpactChunkLifetime
local IMPACT_CHUNK_FADE_DURATION = RollConfig.Crate.ImpactChunkFadeDuration
local IMPACT_CHUNK_MIN_SPREAD = RollConfig.Crate.ImpactChunkMinSpread
local IMPACT_CHUNK_MAX_SPREAD = RollConfig.Crate.ImpactChunkMaxSpread
local IMPACT_CHUNK_MIN_SPEED = RollConfig.Crate.ImpactChunkMinSpeed
local IMPACT_CHUNK_MAX_SPEED = RollConfig.Crate.ImpactChunkMaxSpeed
local CRATE_BREAK_FADE_DURATION = RollConfig.Crate.BreakFadeDuration
local SEED_DEFAULT_SCALE = RollConfig.Reveal.SeedDefaultScale
local SEED_LIFT_HEIGHT = RollConfig.Reveal.SeedLiftHeight
local SEED_PREVIEW_DURATION = RollConfig.Reveal.SeedPreviewDuration
local SEED_REVEAL_FADE_DURATION = RollConfig.Reveal.SeedRevealFadeDuration
local SEED_SHAKE_DEGREES = RollConfig.Reveal.SeedShakeDegrees
local SEED_EXPANDED_SCALE = SEED_DEFAULT_SCALE * RollConfig.Reveal.SeedExpandedScaleMultiplier
local SEED_FINAL_SCALE = SEED_EXPANDED_SCALE
local MISC_START_SCALE = RollConfig.Reveal.MiscStartScale
local MISC_DEFAULT_SCALE = RollConfig.Reveal.MiscDefaultScale
local MISC_FADE_IN_DURATION = RollConfig.Reveal.MiscFadeInDuration
local MISC_LIFT_HEIGHT = RollConfig.Reveal.MiscLiftHeight
local MISC_LIFT_DURATION = RollConfig.Reveal.MiscLiftDuration
local IDLE_BOB_HEIGHT = RollConfig.Reveal.IdleBobHeight
local IDLE_BOB_PERIOD = RollConfig.Reveal.IdleBobPeriod
local IDLE_ROTATION_DEGREES_PER_SECOND = RollConfig.Reveal.IdleRotationDegreesPerSecond
local ACTIVE_VFX_DISTANCE = RollConfig.Reveal.ActiveVfxDistance
local LOCAL_PARTICLE_LIFETIME = RollConfig.Reveal.LocalParticleLifetime
local BUY_PROMPT_DISTANCE = RollConfig.Reveal.BuyPromptDistance
local OFFER_ANCHOR_TOP_OFFSET = RollConfig.Reveal.OfferAnchorTopOffset
local ROLL_SOUND_DISTANCE = 50
local ROLL_SOUND_ROLLOFF_MIN_DISTANCE = 20
local BUTTON_PRESS_DURATION = RollConfig.Button.PressDuration
local BUTTON_RELEASE_DURATION = RollConfig.Button.ReleaseDuration
local BUTTON_UNAVAILABLE_COLOR = RollConfig.Button.UnavailableColor
local ROLL_BUTTON_UNAVAILABLE_ATTR = "RollButtonUnavailable"
local CRATE_ROLL_PROMPT_NAME = "__LocalPrompt_CrateRoll"
local ROLL_OFFER_PENDING_ATTR = "RollOfferPending"
local ACTION_ROLL = "roll"
local ACTION_SHOW_OFFERS = "showOffers"
local ACTION_RESTORE_OFFERS = "restoreOffers"
local ACTION_CLEAR_OFFER = "clearOffer"
local ACTION_CLEAR_OWNER_OFFERS = "clearOwnerOffers"
local ROLL_BILLBOARD_CARD_NAME = "Card"
local PREVIEW_RARITY_SPEED_MULTIPLIER = 3
local PRICE_AFFORDABLE_COLOR = Color3.fromRGB(120, 255, 120)
local PRICE_UNAFFORDABLE_COLOR = Color3.fromRGB(236, 95, 95)

local CRATE_FALL_TWEEN = TweenInfo.new(CRATE_FALL_DURATION, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)

local activeRollToken = 0
local activeReveals = {}
local activeRevealInfoByOfferId = {}
local activeRevealOwnerByOfferId = {}
local activeOfferIdsByOwner = {}
local activeRollEffectsByOfferId = {}
local activeRainbowParticles = {}
local activeRevealAnimations = {}
local pressedButton = nil
local buttonOriginalCFrames = setmetatable({}, { __mode = "k" })
local buttonOriginalColors = setmetatable({}, { __mode = "k" })
local unavailableButtons = setmetatable({}, { __mode = "k" })
local warnedMissingBillboardTemplates = {}
local rng = Random.new()
local started = false

local function isCurrentRoll(token)
	return token == activeRollToken
end

local function trackRollEffect(instance, offerId)
	if offerId == nil then
		return
	end
	local effects = activeRollEffectsByOfferId[offerId]
	if not effects then
		effects = {}
		activeRollEffectsByOfferId[offerId] = effects
	end
	effects[#effects + 1] = instance
end

local function untrackRollEffect(instance, offerId)
	if offerId == nil or instance == nil then
		return
	end
	local effects = activeRollEffectsByOfferId[offerId]
	if not effects then
		return
	end
	for index = #effects, 1, -1 do
		if effects[index] == instance then
			table.remove(effects, index)
			break
		end
	end
	if #effects == 0 then
		activeRollEffectsByOfferId[offerId] = nil
	end
end

local function trackActiveReveal(instance, offerId, ownerUserId, payload)
	if offerId == nil then
		return
	end

	activeReveals[offerId] = instance
	if type(payload) == "table" then
		activeRevealInfoByOfferId[offerId] = {
			category = payload.category,
			seedId = payload.seedId,
			tutorialGuaranteed = payload.tutorialGuaranteed == true,
			ownerUserId = ownerUserId,
		}
	end
	if type(ownerUserId) ~= "number" then
		return
	end

	activeRevealOwnerByOfferId[offerId] = ownerUserId
	local ownerOffers = activeOfferIdsByOwner[ownerUserId]
	if not ownerOffers then
		ownerOffers = {}
		activeOfferIdsByOwner[ownerUserId] = ownerOffers
	end
	ownerOffers[offerId] = true
end

local function ownerUserIdFromPayload(payload)
	if type(payload) == "table" and type(payload.ownerUserId) == "number" then
		return payload.ownerUserId
	end
	return Players.LocalPlayer.UserId
end

local function playerRootPosition()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root.Position or nil
end

local function findSeedTemplate(seedId)
	return Seeds.GetTemplate(seedId)
end

local function findMiscTemplate(miscId)
	return RollRewards.GetMiscTemplate(miscId)
end

local function rewardTemplate(payload)
	if payload.category == RollRewards.Categories.Seed then
		return findSeedTemplate(payload.seedId or payload.rewardId)
	end
	if payload.category == RollRewards.Categories.Misc then
		return findMiscTemplate(payload.miscId or payload.rewardId)
	end
	return nil
end

local function isKnownRewardCategory(category)
	return category == RollRewards.Categories.Seed or category == RollRewards.Categories.Misc
end

local function crateTemplate(name)
	local crates = Assets.Find(Assets.Names.Crates)
	local template = crates and crates:FindFirstChild(name)
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end
	return nil
end

local function rarityParticleTemplate()
	local vfx = Assets.Find(Assets.Names.VFX)
	local template = vfx and vfx:FindFirstChild("RarityParticle")
	if template and template:IsA("ParticleEmitter") then
		return template
	end
	return template and template:FindFirstChildWhichIsA("ParticleEmitter", true) or nil
end

local function effectParts(root)
	local parts = {}
	if root:IsA("BasePart") then
		parts[#parts + 1] = root
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			parts[#parts + 1] = descendant
		end
	end
	return parts
end

local function prepareEffect(root)
	for _, part in ipairs(effectParts(root)) do
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
	end
end

-- Lucky block templates carry a CrateAnimationId attribute (Studio-owned,
-- mirroring the pets' animation-id attributes); the looped track plays from
-- spawn alongside the sway/fall pivots and stops when the crate is destroyed.
local CRATE_ANIMATION_ATTRIBUTE = "CrateAnimationId"

local function playCrateAnimation(crate)
	local animationId = crate:GetAttribute(CRATE_ANIMATION_ATTRIBUTE)
	if type(animationId) ~= "string" or animationId == "" then
		return
	end
	local animator = crate:FindFirstChildWhichIsA("Animator", true)
	if not animator then
		warn("[RollController] Crate " .. crate.Name .. " has " .. CRATE_ANIMATION_ATTRIBUTE .. " but no Animator")
		return
	end

	local animation = Instance.new("Animation")
	animation.Name = "CrateAnimation"
	animation.AnimationId = animationId
	animation.Parent = crate

	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok or not track then
		warn("[RollController] Failed to load crate animation " .. tostring(animationId) .. ": " .. tostring(track))
		return
	end
	track.Looped = true
	track:Play()
end

local function fadeIn(root, duration)
	duration = tonumber(duration) or 0.2
	for _, part in ipairs(effectParts(root)) do
		local targetTransparency = part.Transparency
		part.Transparency = 1
		TweenService:Create(part, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Transparency = targetTransparency,
		}):Play()
	end
end

local function fadeOut(root, duration)
	for _, part in ipairs(effectParts(root)) do
		TweenService:Create(part, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Transparency = 1,
		}):Play()
	end
	task.wait(duration)
end

local function pivotRotation(instance)
	local pivot = instance:IsA("Model") and instance:GetPivot() or instance.CFrame
	return pivot - pivot.Position
end

local function lowestWorldY(instance)
	local lowest = math.huge
	for _, part in ipairs(effectParts(instance)) do
		local halfSize = part.Size * 0.5
		for x = -1, 1, 2 do
			for y = -1, 1, 2 do
				for z = -1, 1, 2 do
					local corner = part.CFrame:PointToWorldSpace(Vector3.new(
						halfSize.X * x,
						halfSize.Y * y,
						halfSize.Z * z
					))
					lowest = math.min(lowest, corner.Y)
				end
			end
		end
	end
	return lowest ~= math.huge and lowest or nil
end

local function highestWorldY(instance)
	local highest = -math.huge
	for _, part in ipairs(effectParts(instance)) do
		local halfSize = part.Size * 0.5
		for x = -1, 1, 2 do
			for y = -1, 1, 2 do
				for z = -1, 1, 2 do
					local corner = part.CFrame:PointToWorldSpace(Vector3.new(
						halfSize.X * x,
						halfSize.Y * y,
						halfSize.Z * z
					))
					highest = math.max(highest, corner.Y)
				end
			end
		end
	end
	return highest ~= -math.huge and highest or nil
end

local function pivotTo(instance, cframe)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	else
		instance.CFrame = cframe
	end
end

local function primaryPart(instance)
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return instance:IsA("BasePart") and instance or nil
end

local function boundsCenter(instance)
	if instance:IsA("Model") then
		local cframe = instance:GetBoundingBox()
		return cframe.Position
	end
	return instance.Position
end

local function offerAttachment(model)
	local primary = primaryPart(model)
	if not primary then
		return nil
	end

	local existing = primary:FindFirstChild("RollOfferAttachment")
	local center = boundsCenter(model)
	local topY = highestWorldY(model) or center.Y
	local worldPosition = Vector3.new(center.X, topY + OFFER_ANCHOR_TOP_OFFSET, center.Z)

	local attachment = existing and existing:IsA("Attachment") and existing or Instance.new("Attachment")
	attachment.Name = "RollOfferAttachment"
	attachment.Position = primary.CFrame:PointToObjectSpace(worldPosition)
	attachment.Parent = primary
	return attachment
end

local function floorLandingCFrame(instance, crateFloor, heightOffset)
	local topY = crateFloor.Position.Y + crateFloor.Size.Y * 0.5
	local pivot = instance:IsA("Model") and instance:GetPivot() or instance.CFrame
	local bottomY = lowestWorldY(instance) or pivot.Position.Y
	local pivotToBottom = pivot.Position.Y - bottomY
	local position = Vector3.new(crateFloor.Position.X, topY + pivotToBottom + (heightOffset or 0), crateFloor.Position.Z)
	return CFrame.new(position) * pivotRotation(instance)
end

local function playSwayFallTween(instance, fromCFrame, toCFrame, token, durationMultiplier)
	durationMultiplier = tonumber(durationMultiplier) or 1
	local fallTween = durationMultiplier == 1 and CRATE_FALL_TWEEN
		or TweenInfo.new(CRATE_FALL_DURATION * durationMultiplier, CRATE_FALL_TWEEN.EasingStyle, CRATE_FALL_TWEEN.EasingDirection)
	local alphaValue = Instance.new("NumberValue")
	alphaValue.Value = 0
	local finalRotation = toCFrame - toCFrame.Position
	local connection = alphaValue:GetPropertyChangedSignal("Value"):Connect(function()
		if not instance.Parent or not isCurrentRoll(token) then
			return
		end

		local alpha = alphaValue.Value
		local easedAlpha = TweenService:GetValue(alpha, CRATE_FALL_TWEEN.EasingStyle, CRATE_FALL_TWEEN.EasingDirection)
		local damp = 1 - alpha
		local basePosition = fromCFrame.Position:Lerp(toCFrame.Position, easedAlpha)
		local sideSway = math.sin(alpha * math.pi * 2) * CRATE_SWAY_AMPLITUDE * damp
		local forwardSway = math.cos(alpha * math.pi * 1.5) * CRATE_SWAY_AMPLITUDE * 0.35 * damp
		local offset = toCFrame.RightVector * sideSway + toCFrame.LookVector * forwardSway
		local tilt = math.rad(CRATE_TILT_DEGREES) * damp
		local rotation = CFrame.Angles(
			math.sin(alpha * math.pi * 2) * tilt,
			math.sin(alpha * math.pi * 1.5) * tilt,
			math.cos(alpha * math.pi * 2) * tilt
		)

		pivotTo(instance, CFrame.new(basePosition + offset) * finalRotation * rotation)
	end)
	local tween = TweenService:Create(alphaValue, fallTween, {
		Value = 1,
	})
	tween:Play()
	tween.Completed:Wait()
	connection:Disconnect()
	alphaValue:Destroy()
	if instance.Parent and isCurrentRoll(token) then
		pivotTo(instance, toCFrame)
	end
	return isCurrentRoll(token)
end

local function isRollButton(button)
	if not (button and button:IsA("BasePart") and button.Name == "Button") then
		return false
	end
	local folder = button.Parent
	local rollArea = folder and folder.Parent
	return folder ~= nil
		and folder:IsA("Folder")
		and folder.Name == "Button"
		and rollArea ~= nil
		and rollArea:IsA("Folder")
		and rollArea.Name == "RollArea"
end

local function rollSoundSource(context)
	if isRollButton(context) then
		return context
	end
	if type(context) == "table" then
		return rollSoundSource(context.button) or rollSoundSource(context.crateFloor)
	end
	if not (context and context:IsA("BasePart")) then
		return nil
	end

	local folder = context.Parent
	local button = folder and folder:IsA("Folder") and folder:FindFirstChild("Button")
	return isRollButton(button) and button or context
end

local function playRollSound(soundName, context, options)
	local source = rollSoundSource(context)
	if not source then
		return nil
	end
	options = type(options) == "table" and table.clone(options) or {}
	options.parent = options.parent or source
	options.range = options.range or ROLL_SOUND_DISTANCE
	options.rollOffMinDistance = options.rollOffMinDistance or ROLL_SOUND_ROLLOFF_MIN_DISTANCE
	return SoundEffects.Play(soundName, options)
end

local function playVariedRollSound(soundName, context, options)
	options = type(options) == "table" and table.clone(options) or {}
	options.pitchVariance = options.pitchVariance or true
	return playRollSound(soundName, context, options)
end

local function setButtonPressed(button, pressed)
	if not (button and button:IsA("BasePart") and button:IsDescendantOf(Workspace)) then
		return
	end
	if pressed and unavailableButtons[button] then
		return
	end

	if not buttonOriginalCFrames[button] then
		buttonOriginalCFrames[button] = button.CFrame
	end

	local originalCFrame = buttonOriginalCFrames[button]
	local targetCFrame = originalCFrame
	local tweenInfo = TweenInfo.new(BUTTON_RELEASE_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	if pressed then
		targetCFrame = originalCFrame + (-originalCFrame.UpVector * (button.Size.Y * 0.75))
		tweenInfo = TweenInfo.new(BUTTON_PRESS_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	end

	TweenService:Create(button, tweenInfo, {
		CFrame = targetCFrame,
	}):Play()
end

local function releasePressedButton()
	if pressedButton then
		setButtonPressed(pressedButton, false)
		pressedButton = nil
	end
end

local function pressButton(button, autoRelease)
	if not isRollButton(button) or unavailableButtons[button] then
		return
	end

	releasePressedButton()
	pressedButton = button
	setButtonPressed(button, true)
	playRollSound(SoundEffects.Names.RollButtonClick, button)
	if autoRelease then
		task.delay(BUTTON_PRESS_DURATION + BUTTON_RELEASE_DURATION, function()
			if pressedButton == button then
				releasePressedButton()
			end
		end)
	end
end

local function setButtonUnavailable(button, unavailable)
	if not (button and button:IsA("BasePart") and button:IsDescendantOf(Workspace)) then
		return
	end
	if not buttonOriginalColors[button] then
		buttonOriginalColors[button] = button.Color
	end

	unavailableButtons[button] = unavailable == true or nil
	button:SetAttribute(ROLL_BUTTON_UNAVAILABLE_ATTR, unavailable == true)
	local targetColor = unavailable and BUTTON_UNAVAILABLE_COLOR or buttonOriginalColors[button]
	TweenService:Create(button, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Color = targetColor,
	}):Play()
end

local function markButtonUnavailableForRoll(button, offers)
	setButtonUnavailable(button, true)
	task.delay(RollConfig.RollVisualDurationForOffers(offers), function()
		setButtonUnavailable(button, false)
	end)
end

local function clearOfferEffects(offerId)
	local effects = activeRollEffectsByOfferId[offerId]
	if effects then
		for _, instance in ipairs(effects) do
			if instance and instance.Parent then
				instance:Destroy()
			end
		end
	end
	activeRollEffectsByOfferId[offerId] = nil
end

local function clearActiveReveal(offerId)
	if offerId ~= nil then
		local ownerUserId = activeRevealOwnerByOfferId[offerId]
		if ownerUserId ~= nil then
			local ownerOffers = activeOfferIdsByOwner[ownerUserId]
			if ownerOffers then
				ownerOffers[offerId] = nil
				if next(ownerOffers) == nil then
					activeOfferIdsByOwner[ownerUserId] = nil
				end
			end
			activeRevealOwnerByOfferId[offerId] = nil
		end
		activeRevealInfoByOfferId[offerId] = nil

		local reveal = activeReveals[offerId]
		if reveal then
			reveal:Destroy()
			activeReveals[offerId] = nil
		end
		clearOfferEffects(offerId)
		return
	end

	local offerIds = {}
	for activeOfferId in pairs(activeReveals) do
		offerIds[#offerIds + 1] = activeOfferId
	end
	for _, activeOfferId in ipairs(offerIds) do
		clearActiveReveal(activeOfferId)
	end
	local effectOfferIds = {}
	for activeOfferId in pairs(activeRollEffectsByOfferId) do
		effectOfferIds[#effectOfferIds + 1] = activeOfferId
	end
	for _, activeOfferId in ipairs(effectOfferIds) do
		clearOfferEffects(activeOfferId)
	end
	activeRevealOwnerByOfferId = {}
	activeRevealInfoByOfferId = {}
	activeOfferIdsByOwner = {}
end

local function clearOwnerReveals(ownerUserId)
	if type(ownerUserId) ~= "number" then
		return
	end

	local ownerOffers = activeOfferIdsByOwner[ownerUserId]
	if not ownerOffers then
		return
	end

	local offerIds = {}
	for offerId in pairs(ownerOffers) do
		offerIds[#offerIds + 1] = offerId
	end
	for _, offerId in ipairs(offerIds) do
		clearActiveReveal(offerId)
	end
end

local function formatPrice(price)
	return NumberFormatter.Currency(price)
end

local function formatChance(payload)
	if payload.rngChanceText then
		return tostring(payload.rngChanceText)
	end
	if payload.chanceN then
		return NumberFormatter.ChanceN(payload.chanceN)
	end
	return "1 in ?"
end

local function rollBillboardTemplate(category)
	if not isKnownRewardCategory(category) then
		warn("[RollController] Unsupported roll billboard category " .. tostring(category))
		return nil
	end

	local templateName = category == RollRewards.Categories.Misc and "MiscRoll" or "SeedRoll"
	local template = BillboardGuiTemplates.Find(templateName)
	if not (template and template:IsA("BillboardGui")) then
		if not warnedMissingBillboardTemplates[templateName] then
			warn("[RollController] Missing " .. BillboardGuiTemplates.Path(templateName) .. " BillboardGui")
			warnedMissingBillboardTemplates[templateName] = true
		end
		return nil
	end

	local card = template:FindFirstChild(ROLL_BILLBOARD_CARD_NAME)
	if card and card:IsA("GuiObject") then
		return template
	end
	local warningKey = templateName .. "." .. ROLL_BILLBOARD_CARD_NAME
	if not warnedMissingBillboardTemplates[warningKey] then
		warn("[RollController] Missing " .. BillboardGuiTemplates.Path(templateName) .. "." .. ROLL_BILLBOARD_CARD_NAME .. " GuiObject")
		warnedMissingBillboardTemplates[warningKey] = true
	end
	return nil
end

local function billboardCard(billboard)
	local card = billboard:FindFirstChild(ROLL_BILLBOARD_CARD_NAME)
	return card and card:IsA("GuiObject") and card or nil
end

local function textLabel(card, name)
	local label = card and card:FindFirstChild(name)
	return label and label:IsA("TextLabel") and label or nil
end

local function setLabel(card, name, text, color)
	local label = textLabel(card, name)
	if not label then
		return
	end
	UiEffects.SetTextStack(label, text)
	if color then
		label.TextColor3 = color
		for _, descendant in ipairs(label:GetDescendants()) do
			if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
				descendant.TextColor3 = color
			elseif descendant:IsA("UIGradient") then
				descendant.Color = ColorSequence.new(color)
			end
		end
		local gradient = label:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient.Color = ColorSequence.new(color)
		end
	end
end

local function applyLabelColor(label, color)
	if not (label and color) then
		return
	end
	label.TextColor3 = color
	for _, descendant in ipairs(label:GetDescendants()) do
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			descendant.TextColor3 = color
		elseif descendant:IsA("UIGradient") then
			descendant.Color = ColorSequence.new(color)
		end
	end
	local gradient = label:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Color = ColorSequence.new(color)
	end
end

local function seedPriceColor(price)
	local numericPrice = tonumber(price)
	if not numericPrice then
		return PRICE_AFFORDABLE_COLOR
	end

	local currency = tonumber(PlayerStateStore.Get(PlayerStateStore.Fields.Currency)) or 0
	return currency >= numericPrice and PRICE_AFFORDABLE_COLOR or PRICE_UNAFFORDABLE_COLOR
end

local function bindSeedPriceColor(billboard, card, price)
	local label = textLabel(card, "PriceLabel")
	if not label then
		return
	end

	local function refresh()
		applyLabelColor(label, seedPriceColor(price))
	end

	refresh()
	local currencyConnection = PlayerStateStore.Observe(PlayerStateStore.Fields.Currency, function()
		RuntimeGuard.Run("RollController.SeedPriceCurrencyChanged", refresh)
	end)
	local destroyConnection = nil
	local function disconnect()
		if currencyConnection then
			currencyConnection:Disconnect()
			currencyConnection = nil
		end
		if destroyConnection then
			destroyConnection:Disconnect()
			destroyConnection = nil
		end
	end
	destroyConnection = RuntimeGuard.Connect(billboard.Destroying, "RollController.SeedPriceBillboardDestroying", disconnect)
end

local function bindPreviewRarityAnimation(billboard, card, payload)
	if payload.previewBeat ~= true or payload.rarity ~= Rarities.Mythical then
		return
	end
	local label = textLabel(card, "RarityLabel")
	if not label then
		return
	end

	local function refresh()
		applyLabelColor(label, Rarities.ColorFor(payload.rarity, os.clock() * PREVIEW_RARITY_SPEED_MULTIPLIER))
	end
	refresh()

	local renderConnection
	local destroyConnection
	local function disconnect()
		if renderConnection then
			renderConnection:Disconnect()
			renderConnection = nil
		end
		if destroyConnection then
			destroyConnection:Disconnect()
			destroyConnection = nil
		end
	end

	renderConnection = RuntimeGuard.Connect(RunService.RenderStepped, "RollController.PreviewRarityRender", function()
		if not billboard.Parent or not label.Parent then
			disconnect()
			return
		end
		refresh()
	end)
	destroyConnection = RuntimeGuard.Connect(billboard.Destroying, "RollController.PreviewRarityDestroying", disconnect)
end

local function addRevealBillboard(model, payload)
	local anchor = offerAttachment(model)
	if not anchor then
		return
	end

	local isMisc = payload.category == RollRewards.Categories.Misc
	local template = rollBillboardTemplate(payload.category)
	if not template then
		return
	end

	local billboard = template:Clone()
	UiEffects.BindBillboardPop(billboard)
	billboard.Name = "RollRevealBillboard"
	billboard.Adornee = anchor
	billboard.AlwaysOnTop = true
	billboard.StudsOffsetWorldSpace = Vector3.zero
	local card = billboardCard(billboard)
	if not card then
		billboard:Destroy()
		return
	end

	local name = tostring(payload.displayName or payload.rewardId or payload.feedType or "Reward")
	if isMisc then
		setLabel(card, "NameLabel", name, Color3.new(1, 1, 1))
		setLabel(card, "PriceLabel", formatPrice(payload.price), PRICE_AFFORDABLE_COLOR)
		billboard.Parent = anchor
		UiEffects.BindBillboardDistancePop(billboard)
		return
	end

	local rarityColor = Rarities.ColorFor(payload.rarity, os.clock()) or Color3.new(1, 1, 1)
	setLabel(card, "NameLabel", name, Color3.new(1, 1, 1))
	setLabel(card, "PriceLabel", "Price: " .. formatPrice(payload.price), seedPriceColor(payload.price))
	setLabel(card, "ChanceLabel", formatChance(payload), Color3.fromRGB(210, 230, 255))
	setLabel(card, "RarityLabel", tostring(payload.rarity or "Unknown"), rarityColor)

	billboard.Parent = anchor
	bindSeedPriceColor(billboard, card, payload.price)
	bindPreviewRarityAnimation(billboard, card, payload)
	UiEffects.BindBillboardDistancePop(billboard)
end

local function scaleClone(clone, scale)
	if clone:IsA("Model") then
		pcall(function()
			clone:ScaleTo(scale)
		end)
	elseif clone:IsA("BasePart") then
		local originalSize = clone:GetAttribute("RollOriginalSize")
		if typeof(originalSize) ~= "Vector3" then
			originalSize = clone.Size
			clone:SetAttribute("RollOriginalSize", originalSize)
		end
		clone.Size = originalSize * scale
	end
end

local function setScaleAtCFrame(clone, scale, cframe)
	scaleClone(clone, scale)
	pivotTo(clone, cframe)
end

local function tweenScaleAtCFrame(clone, baseCFrame, fromScale, toScale, tweenInfo, onStep)
	local scaleValue = Instance.new("NumberValue")
	scaleValue.Value = fromScale
	local connection = scaleValue:GetPropertyChangedSignal("Value"):Connect(function()
		if clone.Parent then
			local cframe = onStep and onStep(scaleValue.Value) or baseCFrame
			setScaleAtCFrame(clone, scaleValue.Value, cframe)
		end
	end)
	setScaleAtCFrame(clone, fromScale, baseCFrame)
	local tween = TweenService:Create(scaleValue, tweenInfo, {
		Value = toScale,
	})
	tween:Play()
	tween.Completed:Wait()
	connection:Disconnect()
	scaleValue:Destroy()
	if clone.Parent then
		local cframe = onStep and onStep(toScale) or baseCFrame
		setScaleAtCFrame(clone, toScale, cframe)
	end
end

local function playImpactChunks(crateFloor)
	local origin = crateFloor.Position + crateFloor.CFrame.UpVector * (crateFloor.Size.Y * 0.5 + 0.5)
	for _ = 1, IMPACT_CHUNK_COUNT do
		local angle = rng:NextNumber(0, math.pi * 2)
		local outward = crateFloor.CFrame.RightVector * math.cos(angle) + crateFloor.CFrame.LookVector * math.sin(angle)
		local spawnOffset = outward * rng:NextNumber(IMPACT_CHUNK_MIN_SPREAD, IMPACT_CHUNK_MAX_SPREAD)
		local chunk = Instance.new("Part")
		chunk.Name = "RollCrateImpactChunk"
		chunk.Size = IMPACT_CHUNK_SIZE
		chunk.Color = crateFloor.Color
		chunk.Material = crateFloor.Material
		chunk.Anchored = false
		chunk.CanCollide = false
		chunk.CanTouch = false
		chunk.CanQuery = false
		chunk.CFrame = CFrame.new(origin + spawnOffset)
		chunk.Parent = Workspace

		local horizontal = outward * rng:NextNumber(IMPACT_CHUNK_MIN_SPEED, IMPACT_CHUNK_MAX_SPEED)
		local upward = crateFloor.CFrame.UpVector * rng:NextNumber(8, 16)
		chunk.AssemblyLinearVelocity = horizontal + upward
		chunk.AssemblyAngularVelocity = Vector3.new(
			rng:NextNumber(-6, 6),
			rng:NextNumber(-6, 6),
			rng:NextNumber(-6, 6)
		)

		task.delay(math.max(IMPACT_CHUNK_LIFETIME - IMPACT_CHUNK_FADE_DURATION, 0), function()
			if not chunk.Parent then
				return
			end
			TweenService:Create(chunk, TweenInfo.new(IMPACT_CHUNK_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Transparency = 1,
			}):Play()
		end)
		task.delay(IMPACT_CHUNK_LIFETIME, function()
			if chunk.Parent then
				chunk:Destroy()
			end
		end)
	end
end

local function breakCrate(crate, crateFloor)
	playVariedRollSound(SoundEffects.Names.CrateBreak, crateFloor)
	playImpactChunks(crateFloor)
	fadeOut(crate, CRATE_BREAK_FADE_DURATION)
end

local function setBlackNeon(root)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("Decal")
			or descendant:IsA("Texture")
			or descendant:IsA("SurfaceAppearance")
			or descendant:IsA("SurfaceGui")
			or descendant:IsA("BillboardGui")
			or descendant:IsA("ParticleEmitter")
			or descendant:IsA("Trail")
			or descendant:IsA("Beam")
			or descendant:IsA("Highlight")
		then
			descendant:Destroy()
		elseif descendant:IsA("SpecialMesh") then
			descendant.TextureId = ""
			descendant.VertexColor = Vector3.new(0, 0, 0)
		end
	end

	for _, part in ipairs(effectParts(root)) do
		part.Material = Enum.Material.Neon
		part.Color = Color3.new(0, 0, 0)
		part.Transparency = 0.08
		pcall(function()
			part.MaterialVariant = ""
		end)
		pcall(function()
			part.UsePartColor = true
		end)
		if part:IsA("MeshPart") then
			part.TextureID = ""
		end
	end
end

local function makeRewardClone(payload, name, scale, blackNeon)
	local template = rewardTemplate(payload)
	if not template then
		return nil
	end

	local clone = template:Clone()
	clone.Name = name or ("RollReveal_" .. tostring(payload.rewardId or payload.seedId or payload.miscId or "Reward"))
	prepareEffect(clone)
	scaleClone(clone, scale or 1)
	if blackNeon then
		setBlackNeon(clone)
	end
	return clone
end

local function setParticleColor(emitter, color)
	if emitter and emitter:IsA("ParticleEmitter") and typeof(color) == "Color3" then
		emitter.Color = ColorSequence.new(color)
	end
end

local function attachRarityParticle(model, color)
	local template = rarityParticleTemplate()
	local primary = primaryPart(model)
	if not (template and primary) then
		return nil
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "RollRarityParticleAttachment"
	attachment.Position = Vector3.zero
	attachment.Parent = primary

	local emitter = template:Clone()
	emitter.Name = "RollRarityParticle"
	setParticleColor(emitter, color or Color3.new(1, 1, 1))
	emitter.Enabled = true
	emitter.Parent = attachment
	return emitter
end

local function tweenParticleColor(emitter, fromColor, toColor, duration)
	if not emitter then
		task.wait(duration)
		return
	end

	local alphaValue = Instance.new("NumberValue")
	alphaValue.Value = 0
	local connection = alphaValue:GetPropertyChangedSignal("Value"):Connect(function()
		if emitter.Parent then
			setParticleColor(emitter, fromColor:Lerp(toColor, alphaValue.Value))
		end
	end)
	local tween = TweenService:Create(alphaValue, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Value = 1,
	})
	tween:Play()
	tween.Completed:Wait()
	connection:Disconnect()
	alphaValue:Destroy()
	if emitter.Parent then
		setParticleColor(emitter, toColor)
	end
end

local function startRainbowParticle(emitter, particleExpiresAt)
	if not emitter then
		return
	end

	activeRainbowParticles[emitter] = {
		expiresAt = particleExpiresAt,
	}
end

local function isWithinActiveVfxDistance(baseCFrame)
	local rootPosition = playerRootPosition()
	return rootPosition ~= nil and (rootPosition - baseCFrame.Position).Magnitude <= ACTIVE_VFX_DISTANCE
end

local function setRevealParticlesEnabled(instance, enabled)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = enabled
		end
	end
end

local function startIdleAnimation(instance, baseCFrame, token, particleExpiresAt)
	activeRevealAnimations[instance] = {
		baseCFrame = baseCFrame,
		bobPeriod = math.max(IDLE_BOB_PERIOD, 0.01),
		particleExpiresAt = particleExpiresAt,
		rotationSpeed = math.rad(IDLE_ROTATION_DEGREES_PER_SECOND),
		startTime = os.clock(),
		token = token,
		wasActive = nil,
		wereParticlesEnabled = nil,
	}
end

local function stepRainbowParticles()
	local now = os.clock()
	for emitter, record in pairs(activeRainbowParticles) do
		if not emitter.Parent or (record.expiresAt ~= nil and now >= record.expiresAt) then
			activeRainbowParticles[emitter] = nil
		else
			setParticleColor(emitter, Rarities.RainbowColorAt(now))
		end
	end
end

local function stepRevealAnimations()
	local now = os.clock()
	for instance, record in pairs(activeRevealAnimations) do
		if not instance.Parent or (record.token ~= nil and not isCurrentRoll(record.token)) then
			activeRevealAnimations[instance] = nil
			continue
		end

		local isActive = isWithinActiveVfxDistance(record.baseCFrame)
		local particlesEnabled = isActive and (record.particleExpiresAt == nil or now < record.particleExpiresAt)
		if particlesEnabled ~= record.wereParticlesEnabled then
			setRevealParticlesEnabled(instance, particlesEnabled)
			record.wereParticlesEnabled = particlesEnabled
		end
		if isActive ~= record.wasActive then
			if not isActive then
				pivotTo(instance, record.baseCFrame)
			end
			record.wasActive = isActive
		end
		if not isActive then
			continue
		end

		local elapsed = now - record.startTime
		local bob = math.sin((elapsed / record.bobPeriod) * math.pi * 2) * IDLE_BOB_HEIGHT
		local rotation = CFrame.Angles(0, elapsed * record.rotationSpeed, 0)
		pivotTo(instance, (record.baseCFrame + Vector3.new(0, bob, 0)) * rotation)
	end
end

local function stepRollRenderEffects()
	if next(activeRainbowParticles) ~= nil then
		stepRainbowParticles()
	end
	if next(activeRevealAnimations) ~= nil then
		stepRevealAnimations()
	end
end

local function addPurchasePrompt(model, payload)
	local anchor = offerAttachment(model)
	if not anchor then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "RollOfferBuyPrompt"
	prompt.ActionText = "Buy"
	prompt.ObjectText = ""
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = BUY_PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	if payload.category == RollRewards.Categories.Seed then
		prompt:SetAttribute("PromptStudsOffset", Vector3.new(0, 0, -0.5))
	end
	prompt.Parent = anchor
	LocalPrompts.RegisterExternalPrompt(prompt, function()
		return activeReveals[payload.offerId] ~= nil and prompt:GetAttribute(ROLL_OFFER_PENDING_ATTR) ~= true
	end, {
		highlightTarget = payload.category == RollRewards.Categories.Seed and model or nil,
	})
	RuntimeGuard.Connect(prompt.Triggered, "RollController.PurchasePromptTriggered", function()
		if activeReveals[payload.offerId] == nil then
			return
		end
		prompt:SetAttribute(ROLL_OFFER_PENDING_ATTR, true)
		prompt.Enabled = false
		Remotes.get(Remotes.Names.CrateRollPurchaseRequest):FireServer(payload.offerId)
	end)
end

local function seedRarityColor(payload)
	return Rarities.ColorFor(payload.rarity, os.clock()) or Color3.new(1, 1, 1)
end

local function previewPayloadFor(parentPayload, preview)
	if type(preview) ~= "table" then
		return nil
	end

	local out = table.clone(preview)
	out.category = RollRewards.Categories.Seed
	out.offerId = parentPayload.offerId
	out.ownerUserId = ownerUserIdFromPayload(parentPayload)
	out.previewBeat = true
	return out
end

local function playSeedBeatTween(clone, floorCFrame, liftedCFrame, token, onPop)
	local liftAlpha = Instance.new("NumberValue")
	liftAlpha.Value = 0
	local liftTween = nil
	local popPlayed = false
	local liftConnection = liftAlpha:GetPropertyChangedSignal("Value"):Connect(function()
		if not clone.Parent then
			return
		end
		if not isCurrentRoll(token) then
			clone:Destroy()
			if liftTween then
				liftTween:Cancel()
			end
			return
		end
		local alpha = liftAlpha.Value
		local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		if not popPlayed and alpha >= 0.08 then
			popPlayed = true
			if onPop then
				onPop()
			end
		end
		local currentScale = SEED_DEFAULT_SCALE + (SEED_EXPANDED_SCALE - SEED_DEFAULT_SCALE) * eased
		local basePosition = floorCFrame.Position:Lerp(liftedCFrame.Position, eased)
		local shake = math.sin(alpha * math.pi * 10) * math.rad(SEED_SHAKE_DEGREES)
		local currentCFrame = CFrame.new(basePosition) * (floorCFrame - floorCFrame.Position) * CFrame.Angles(0, shake, shake * 0.35)
		setScaleAtCFrame(clone, currentScale, currentCFrame)
	end)
	setScaleAtCFrame(clone, SEED_DEFAULT_SCALE, floorCFrame)
	liftTween = TweenService:Create(liftAlpha, TweenInfo.new(SEED_PREVIEW_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Value = 1,
	})
	liftTween:Play()
	liftTween.Completed:Wait()
	liftConnection:Disconnect()
	liftAlpha:Destroy()
	if not popPlayed and clone.Parent and isCurrentRoll(token) and onPop then
		onPop()
	end
	if clone.Parent and isCurrentRoll(token) then
		setScaleAtCFrame(clone, SEED_FINAL_SCALE, liftedCFrame)
	end
	return isCurrentRoll(token)
end

local function playSeedPreviewBeat(preview, crateFloor, token, index)
	local clone = makeRewardClone(preview, "RollPreview_" .. tostring(index) .. "_" .. tostring(preview.seedId or preview.rewardId), SEED_DEFAULT_SCALE, true)
	if not clone then
		return isCurrentRoll(token)
	end

	clone.Parent = Workspace
	trackRollEffect(clone, preview.offerId)
	local floorCFrame = floorLandingCFrame(clone, crateFloor, 0)
	local liftedCFrame = floorCFrame + Vector3.new(0, SEED_LIFT_HEIGHT, 0)
	fadeIn(clone)
	attachRarityParticle(clone, Color3.new(1, 1, 1))
	addRevealBillboard(clone, preview)

	local completed = playSeedBeatTween(clone, floorCFrame, liftedCFrame, token, function()
		playVariedRollSound(SoundEffects.Names.FruitPop, crateFloor)
	end)
	if clone.Parent then
		clone:Destroy()
	end
	untrackRollEffect(clone, preview.offerId)
	return completed
end

local function playSeedPreviewSequence(payload, crateFloor, token)
	if type(payload.previewSeeds) ~= "table" then
		return isCurrentRoll(token)
	end

	for index, preview in ipairs(payload.previewSeeds) do
		local previewPayload = previewPayloadFor(payload, preview)
		if previewPayload and not playSeedPreviewBeat(previewPayload, crateFloor, token, index) then
			return false
		end
	end
	return isCurrentRoll(token)
end

local function playSeedReveal(payload, crateFloor, token)
	if not isCurrentRoll(token) then
		return
	end
	clearActiveReveal(payload.offerId)
	if not playSeedPreviewSequence(payload, crateFloor, token) then
		return
	end

	local blackClone = makeRewardClone(payload, "RollFinalBlack_" .. tostring(payload.rewardId or payload.seedId), SEED_DEFAULT_SCALE, true)
	if not blackClone then
		return
	end

	blackClone.Parent = Workspace
	trackRollEffect(blackClone, payload.offerId)
	local floorCFrame = floorLandingCFrame(blackClone, crateFloor, 0)
	local liftedCFrame = floorCFrame + Vector3.new(0, SEED_LIFT_HEIGHT, 0)
	fadeIn(blackClone)
	attachRarityParticle(blackClone, Color3.new(1, 1, 1))
	addRevealBillboard(blackClone, payload)
	playVariedRollSound(SoundEffects.Names.FruitPop, crateFloor)

	if not playSeedBeatTween(blackClone, floorCFrame, liftedCFrame, token) then
		if blackClone.Parent then
			blackClone:Destroy()
		end
		untrackRollEffect(blackClone, payload.offerId)
		return
	end

	local clone = makeRewardClone(payload, "RollReveal_" .. tostring(payload.rewardId or payload.seedId), SEED_FINAL_SCALE, false)
	if not clone then
		if blackClone.Parent then
			blackClone:Destroy()
		end
		untrackRollEffect(blackClone, payload.offerId)
		return
	end

	clone.Parent = Workspace
	trackRollEffect(clone, payload.offerId)
	pivotTo(clone, liftedCFrame)
	fadeIn(clone, SEED_REVEAL_FADE_DURATION)
	playRollSound(SoundEffects.Names.RollReveal, crateFloor)

	local emitter = attachRarityParticle(clone, Color3.new(1, 1, 1))
	local particleExpiresAt = os.clock() + LOCAL_PARTICLE_LIFETIME
	local targetColor = seedRarityColor(payload)
	task.spawn(tweenParticleColor, emitter, Color3.new(1, 1, 1), targetColor, SEED_REVEAL_FADE_DURATION)
	fadeOut(blackClone, SEED_REVEAL_FADE_DURATION)
	if blackClone.Parent then
		blackClone:Destroy()
	end
	untrackRollEffect(blackClone, payload.offerId)
	if not isCurrentRoll(token) then
		if clone.Parent then
			clone:Destroy()
		end
		untrackRollEffect(clone, payload.offerId)
		return
	end
	if Rarities.Get(payload.rarity) and Rarities.Get(payload.rarity).Animated then
		startRainbowParticle(emitter, particleExpiresAt)
	else
		setParticleColor(emitter, targetColor)
	end
	trackActiveReveal(clone, payload.offerId, ownerUserIdFromPayload(payload), payload)
	addRevealBillboard(clone, payload)
	if ownerUserIdFromPayload(payload) == Players.LocalPlayer.UserId then
		addPurchasePrompt(clone, payload)
	end
	startIdleAnimation(clone, liftedCFrame, token, particleExpiresAt)
end

local function playMiscReveal(payload, crateFloor, token)
	if not isCurrentRoll(token) then
		return
	end
	clearActiveReveal(payload.offerId)

	local clone = makeRewardClone(payload, "RollReveal_" .. tostring(payload.rewardId or payload.miscId), MISC_DEFAULT_SCALE, false)
	if not clone then
		return
	end

	clone.Parent = Workspace
	trackActiveReveal(clone, payload.offerId, ownerUserIdFromPayload(payload), payload)
	trackRollEffect(clone, payload.offerId)
	local floorCFrame = floorLandingCFrame(clone, crateFloor, 0)
	local liftedCFrame = floorCFrame + Vector3.new(0, MISC_LIFT_HEIGHT, 0)
	setScaleAtCFrame(clone, MISC_START_SCALE, floorCFrame)
	fadeIn(clone)
	playRollSound(SoundEffects.Names.RollReveal, crateFloor)

	tweenScaleAtCFrame(clone, floorCFrame, MISC_START_SCALE, MISC_DEFAULT_SCALE, TweenInfo.new(MISC_FADE_IN_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
	local alphaValue = Instance.new("NumberValue")
	alphaValue.Value = 0
	local connection = alphaValue:GetPropertyChangedSignal("Value"):Connect(function()
		if clone.Parent then
			local eased = TweenService:GetValue(alphaValue.Value, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			pivotTo(clone, floorCFrame:Lerp(liftedCFrame, eased))
		end
	end)
	local liftTween = TweenService:Create(alphaValue, TweenInfo.new(MISC_LIFT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Value = 1,
	})
	liftTween:Play()
	liftTween.Completed:Wait()
	connection:Disconnect()
	alphaValue:Destroy()
	if not isCurrentRoll(token) then
		if clone.Parent then
			clone:Destroy()
		end
		return
	end

	addRevealBillboard(clone, payload)
	if ownerUserIdFromPayload(payload) == Players.LocalPlayer.UserId then
		addPurchasePrompt(clone, payload)
	end
	startIdleAnimation(clone, liftedCFrame, token)
end

local revealHandlers = {
	[RollRewards.Categories.Seed] = playSeedReveal,
	[RollRewards.Categories.Misc] = playMiscReveal,
}

local function showPublicOffer(payload, options)
	options = type(options) == "table" and options or {}
	local crateFloor = payload.crateFloor
	if not (crateFloor and crateFloor:IsA("BasePart") and crateFloor:IsDescendantOf(Workspace)) then
		return
	end
	if not isKnownRewardCategory(payload.category) then
		warn("[RollController] Unsupported public roll reward category " .. tostring(payload.category))
		return
	end

	clearActiveReveal(payload.offerId)
	local scale = payload.category == RollRewards.Categories.Seed and SEED_DEFAULT_SCALE or MISC_DEFAULT_SCALE
	local clone = makeRewardClone(payload, "RollPublicReveal_" .. tostring(payload.rewardId or payload.seedId or payload.miscId), scale, false)
	if not clone then
		return
	end

	clone.Parent = Workspace
	trackActiveReveal(clone, payload.offerId, ownerUserIdFromPayload(payload), payload)
	trackRollEffect(clone, payload.offerId)
	local liftHeight = payload.category == RollRewards.Categories.Seed and SEED_LIFT_HEIGHT or MISC_LIFT_HEIGHT
	local baseCFrame = floorLandingCFrame(clone, crateFloor, liftHeight)
	pivotTo(clone, baseCFrame)
	fadeIn(clone)
	setRevealParticlesEnabled(clone, false)
	addRevealBillboard(clone, payload)
	if options.addPurchasePromptForOwner == true and ownerUserIdFromPayload(payload) == Players.LocalPlayer.UserId then
		addPurchasePrompt(clone, payload)
	end
	startIdleAnimation(clone, baseCFrame, nil, 0)
end

local function playCrateFall(payload, token)
	if not isCurrentRoll(token) then
		return
	end

	local crateFloor = payload.crateFloor
	if not (crateFloor and crateFloor:IsA("BasePart") and crateFloor:IsDescendantOf(Workspace)) then
		return
	end

	local template = crateTemplate(payload.crateTemplateName or payload.crateId)
	if not template then
		warn("[RollController] Missing crate template " .. tostring(payload.crateTemplateName or payload.crateId))
		return
	end

	local crate = template:Clone()
	crate.Name = "RollCrate_" .. tostring(payload.crateId or template.Name)
	prepareEffect(crate)
	crate.Parent = Workspace
	trackRollEffect(crate, payload.offerId)
	playCrateAnimation(crate)

	local endCFrame = floorLandingCFrame(crate, crateFloor, 0)
	local startCFrame = endCFrame + Vector3.new(0, CRATE_START_HEIGHT, 0)
	pivotTo(crate, startCFrame)
	fadeIn(crate)

	local crateConfig = RollChances.GetCrate(payload.crateId)
	local fallMultiplier = tonumber(payload.fallDurationMultiplier)
		or tonumber(payload.crateFallDurationMultiplier)
		or (crateConfig and crateConfig.FallDurationMultiplier)
		or 1
	if not playSwayFallTween(crate, startCFrame, endCFrame, token, fallMultiplier) then
		-- Roll superseded mid-fall. clearOwnerReveals can't reach this offer
		-- (trackActiveReveal only runs after landing), so reap the crate here
		-- or it stays in Workspace forever with its looped animation playing.
		clearOfferEffects(payload.offerId)
		return
	end

	breakCrate(crate, crateFloor)
	if crate.Parent then
		crate:Destroy()
	end
	if not isCurrentRoll(token) then
		clearOfferEffects(payload.offerId)
		return
	end

	local handler = revealHandlers[payload.category]
	if handler then
		handler(payload, crateFloor, token)
	else
		warn("[RollController] Unsupported roll reward category " .. tostring(payload.category))
	end
end

local function collectPayloadOffers(payload)
	local offers = {}
	if type(payload.offers) == "table" then
		for _, offer in ipairs(payload.offers) do
			if type(offer) == "table" then
				offers[#offers + 1] = offer
			end
		end
	else
		offers[1] = payload
	end
	return offers
end

function RollController.start()
	if started then
		return
	end
	started = true

	local player = Players.LocalPlayer
	local mouse = player:GetMouse()

	RuntimeGuard.Connect(RunService.RenderStepped, "RollController.RenderStepped", stepRollRenderEffects)

	RuntimeGuard.Connect(mouse.Button1Down, "RollController.MouseButton1Down", function()
		local target = mouse.Target
		if isRollButton(target) then
			pressButton(target, false)
		end
	end)
	RuntimeGuard.Connect(mouse.Button1Up, "RollController.MouseButton1Up", releasePressedButton)

	RuntimeGuard.Connect(ProximityPromptService.PromptTriggered, "RollController.PromptTriggered", function(prompt)
		if prompt.Name == CRATE_ROLL_PROMPT_NAME and prompt.Parent and prompt.Parent:IsA("Attachment") then
			pressButton(prompt.Parent.Parent, true)
		end
	end)

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.CrateRollEffect).OnClientEvent, "RollController.CrateRollEffect", function(payload)
		if type(payload) ~= "table" then
			return
		end

		local action = payload.action or ACTION_ROLL
		if action == ACTION_CLEAR_OFFER then
			clearActiveReveal(payload.offerId)
			return
		end
		if action == ACTION_CLEAR_OWNER_OFFERS then
			clearOwnerReveals(payload.ownerUserId)
			return
		end
		if action == ACTION_SHOW_OFFERS then
			local ownerUserId = payload.ownerUserId
			if ownerUserId == player.UserId then
				return
			end
			clearOwnerReveals(ownerUserId)
			for _, offer in ipairs(collectPayloadOffers(payload)) do
				offer.ownerUserId = ownerUserId
				offer.rollBatchId = offer.rollBatchId or payload.rollBatchId
				RuntimeGuard.Spawn("RollController.ShowPublicOffer", showPublicOffer, offer)
			end
			return
		end
		if action == ACTION_RESTORE_OFFERS then
			local ownerUserId = payload.ownerUserId
			if type(ownerUserId) ~= "number" then
				return
			end
			clearOwnerReveals(ownerUserId)
			for _, offer in ipairs(collectPayloadOffers(payload)) do
				offer.ownerUserId = ownerUserId
				offer.rollBatchId = offer.rollBatchId or payload.rollBatchId
				RuntimeGuard.Spawn("RollController.RestoreOffer", showPublicOffer, offer, {
					addPurchasePromptForOwner = true,
				})
			end
			return
		end
		if action ~= ACTION_ROLL then
			return
		end

		local offers = collectPayloadOffers(payload)
		if #offers == 0 then
			return
		end

		activeRollToken += 1
		local token = activeRollToken
		local ownerUserId = ownerUserIdFromPayload(payload)
		clearOwnerReveals(ownerUserId)
		markButtonUnavailableForRoll(payload.button, offers)
		for _, offer in ipairs(offers) do
			offer.ownerUserId = ownerUserId
			if offer.button == nil then
				offer.button = payload.button
			end
			RuntimeGuard.Spawn("RollController.PlayCrateFall", playCrateFall, offer, token)
		end
	end)

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.CrateRollPurchaseResult).OnClientEvent, "RollController.PurchaseResult", function(payload)
		if type(payload) ~= "table" then
			return
		end
		if payload.success then
			clearActiveReveal(payload.offerId)
			return
		end
		UiEffects.PlayError()

		local reveal = activeReveals[payload.offerId]
		local prompt = reveal and reveal:FindFirstChild("RollOfferBuyPrompt", true)
		if prompt and prompt:IsA("ProximityPrompt") then
			prompt:SetAttribute(ROLL_OFFER_PENDING_ATTR, false)
			prompt.Enabled = false
		end
	end)
end

function RollController.GetActiveTutorialReveal(seedId)
	for offerId, info in pairs(activeRevealInfoByOfferId) do
		local reveal = activeReveals[offerId]
		if reveal
			and reveal.Parent
			and info.ownerUserId == Players.LocalPlayer.UserId
			and info.category == RollRewards.Categories.Seed
			and info.seedId == seedId
			and info.tutorialGuaranteed == true then
			return reveal
		end
	end
	return nil
end

return RollController
