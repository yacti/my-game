local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rarities = require(Shared:WaitForChild("Rarities"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RollConfig = require(Shared:WaitForChild("RollConfig"))
local RollRewards = require(Shared:WaitForChild("RollRewards"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local LocalPrompts = require(script.Parent:WaitForChild("LocalPrompts"))

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
local SEED_LIFT_DURATION = RollConfig.Reveal.SeedLiftDuration
local SEED_SHAKE_DURATION = RollConfig.Reveal.SeedShakeDuration
local SEED_SHAKE_DEGREES = RollConfig.Reveal.SeedShakeDegrees
local SEED_EXPANDED_SCALE = SEED_DEFAULT_SCALE * RollConfig.Reveal.SeedExpandedScaleMultiplier
local SEED_POP_IN_SCALE = SEED_DEFAULT_SCALE * RollConfig.Reveal.SeedPopInScaleMultiplier
local SEED_POP_IN_DURATION = RollConfig.Reveal.SeedPopInDuration
local SEED_POP_OUT_DURATION = RollConfig.Reveal.SeedPopOutDuration
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
local BILLBOARD_MAX_DISTANCE = RollConfig.Reveal.BillboardMaxDistance
local OFFER_ANCHOR_TOP_OFFSET = RollConfig.Reveal.OfferAnchorTopOffset
local BUTTON_PRESS_DURATION = RollConfig.Button.PressDuration
local BUTTON_RELEASE_DURATION = RollConfig.Button.ReleaseDuration
local BUTTON_UNAVAILABLE_COLOR = RollConfig.Button.UnavailableColor
local ROLL_BUTTON_UNAVAILABLE_ATTR = "RollButtonUnavailable"
local CRATE_ROLL_PROMPT_NAME = "__LocalPrompt_CrateRoll"
local ROLL_OFFER_PENDING_ATTR = "RollOfferPending"
local ACTION_ROLL = "roll"
local ACTION_SHOW_OFFERS = "showOffers"
local ACTION_CLEAR_OFFER = "clearOffer"
local ACTION_CLEAR_OWNER_OFFERS = "clearOwnerOffers"

local CRATE_FALL_TWEEN = TweenInfo.new(CRATE_FALL_DURATION, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)
local SEED_POP_IN_TWEEN = TweenInfo.new(SEED_POP_IN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SEED_POP_OUT_TWEEN = TweenInfo.new(SEED_POP_OUT_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local activeRollToken = 0
local activeReveals = {}
local activeRevealOwnerByOfferId = {}
local activeOfferIdsByOwner = {}
local activeRollEffectsByOfferId = {}
local pressedButton = nil
local buttonOriginalCFrames = setmetatable({}, { __mode = "k" })
local buttonOriginalColors = setmetatable({}, { __mode = "k" })
local unavailableButtons = setmetatable({}, { __mode = "k" })
local warnedMissingBillboardTemplates = {}
local rng = Random.new()

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

local function trackActiveReveal(instance, offerId, ownerUserId)
	if offerId == nil then
		return
	end

	activeReveals[offerId] = instance
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
	local crates = ReplicatedStorage:FindFirstChild("Crates")
	local template = crates and crates:FindFirstChild(name)
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end
	return nil
end

local function rarityParticleTemplate()
	local vfx = ReplicatedStorage:FindFirstChild("VFX")
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

local function fadeIn(root)
	for _, part in ipairs(effectParts(root)) do
		local targetTransparency = part.Transparency
		part.Transparency = 1
		TweenService:Create(part, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
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

local function playSwayFallTween(instance, fromCFrame, toCFrame, token)
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
	local tween = TweenService:Create(alphaValue, CRATE_FALL_TWEEN, {
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

local function markButtonUnavailableForRoll(button)
	setButtonUnavailable(button, true)
	task.delay(RollConfig.RollVisualDuration(), function()
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
	local amount = tonumber(price) or 0
	return "$" .. tostring(math.max(math.floor(amount), 0))
end

local function rollBillboardTemplate(category)
	if not isKnownRewardCategory(category) then
		warn("[RollController] Unsupported roll billboard category " .. tostring(category))
		return nil
	end

	local ui = ReplicatedStorage:FindFirstChild("UI")
	local folder = ui and ui:FindFirstChild("RollBillboardGUI")
	local templateName = category == RollRewards.Categories.Misc and "Misc" or "Seed"
	local template = folder and folder:FindFirstChild(templateName)
	if template and template:IsA("BillboardGui") then
		return template
	end
	if not warnedMissingBillboardTemplates[templateName] then
		warn("[RollController] Missing ReplicatedStorage.UI.RollBillboardGUI." .. templateName .. " BillboardGui")
		warnedMissingBillboardTemplates[templateName] = true
	end
	return nil
end

local function textLabel(root, name)
	local label = root:FindFirstChild(name, true)
	return label and label:IsA("TextLabel") and label or nil
end

local function setLabel(root, name, text, color)
	local label = textLabel(root, name)
	if not label then
		return
	end
	label.Text = text
	if color then
		label.TextColor3 = color
	end
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
	billboard.Name = "RollRevealBillboard"
	billboard.Adornee = anchor
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = BILLBOARD_MAX_DISTANCE
	billboard.StudsOffsetWorldSpace = Vector3.zero

	local name = tostring(payload.displayName or payload.rewardId or payload.feedType or "Reward")
	if isMisc then
		setLabel(billboard, "NameLabel", name, Color3.new(1, 1, 1))
		setLabel(billboard, "PriceLabel", formatPrice(payload.price), Color3.fromRGB(120, 255, 120))
		billboard.Parent = anchor
		return
	end

	local rarityColor = Rarities.ColorFor(payload.rarity, os.clock()) or Color3.new(1, 1, 1)
	setLabel(billboard, "NameLabel", name, Color3.new(1, 1, 1))
	setLabel(billboard, "PriceLabel", "Price: " .. formatPrice(payload.price), Color3.fromRGB(120, 255, 120))
	setLabel(billboard, "ChanceLabel", "Chance: " .. tostring(payload.rngChanceText or ("1 in " .. tostring(payload.chanceN or "?"))), Color3.fromRGB(210, 230, 255))
	setLabel(billboard, "RarityLabel", "Rarity: " .. tostring(payload.rarity or "Unknown"), rarityColor)

	billboard.Parent = anchor
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

	local connection
	connection = RunService.RenderStepped:Connect(function()
		if not emitter.Parent or (particleExpiresAt ~= nil and os.clock() >= particleExpiresAt) then
			connection:Disconnect()
			return
		end
		setParticleColor(emitter, Rarities.RainbowColorAt(os.clock()))
	end)
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
	local startTime = os.clock()
	local rotationSpeed = math.rad(IDLE_ROTATION_DEGREES_PER_SECOND)
	local bobPeriod = math.max(IDLE_BOB_PERIOD, 0.01)
	local wasActive = nil
	local wereParticlesEnabled = nil
	local connection
	connection = RunService.RenderStepped:Connect(function()
		if not instance.Parent or (token ~= nil and not isCurrentRoll(token)) then
			connection:Disconnect()
			return
		end

		local isActive = isWithinActiveVfxDistance(baseCFrame)
		local particlesEnabled = isActive and (particleExpiresAt == nil or os.clock() < particleExpiresAt)
		if particlesEnabled ~= wereParticlesEnabled then
			setRevealParticlesEnabled(instance, particlesEnabled)
			wereParticlesEnabled = particlesEnabled
		end
		if isActive ~= wasActive then
			if not isActive then
				pivotTo(instance, baseCFrame)
			end
			wasActive = isActive
		end
		if not isActive then
			return
		end

		local elapsed = os.clock() - startTime
		local bob = math.sin((elapsed / bobPeriod) * math.pi * 2) * IDLE_BOB_HEIGHT
		local rotation = CFrame.Angles(0, elapsed * rotationSpeed, 0)
		pivotTo(instance, (baseCFrame + Vector3.new(0, bob, 0)) * rotation)
	end)
	instance.Destroying:Connect(function()
		if connection.Connected then
			connection:Disconnect()
		end
	end)
end

local function addPurchasePrompt(model, payload)
	local anchor = offerAttachment(model)
	if not anchor then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "RollOfferBuyPrompt"
	prompt.ActionText = "Buy " .. formatPrice(payload.price)
	prompt.ObjectText = tostring(payload.displayName or payload.rewardId or payload.feedType or "Reward")
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = BUY_PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	prompt.Parent = anchor
	LocalPrompts.RegisterExternalPrompt(prompt, function()
		return activeReveals[payload.offerId] ~= nil and prompt:GetAttribute(ROLL_OFFER_PENDING_ATTR) ~= true
	end)
	prompt.Triggered:Connect(function()
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

local function playSeedReveal(payload, crateFloor, token)
	if not isCurrentRoll(token) then
		return
	end
	clearActiveReveal(payload.offerId)

	local blackClone = makeRewardClone(payload, "RollFinalBlack_" .. tostring(payload.rewardId or payload.seedId), SEED_DEFAULT_SCALE, true)
	if not blackClone then
		return
	end

	blackClone.Parent = Workspace
	trackRollEffect(blackClone, payload.offerId)
	local floorCFrame = floorLandingCFrame(blackClone, crateFloor, 0)
	local liftedCFrame = floorCFrame + Vector3.new(0, SEED_LIFT_HEIGHT, 0)
	pivotTo(blackClone, floorCFrame)
	attachRarityParticle(blackClone, Color3.new(1, 1, 1))

	local liftAlpha = Instance.new("NumberValue")
	liftAlpha.Value = 0
	local liftTween = nil
	local liftConnection = liftAlpha:GetPropertyChangedSignal("Value"):Connect(function()
		if not blackClone.Parent then
			return
		end
		if not isCurrentRoll(token) then
			blackClone:Destroy()
			if liftTween then
				liftTween:Cancel()
			end
			return
		end
		local alpha = liftAlpha.Value
		local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local currentScale = SEED_DEFAULT_SCALE + (SEED_EXPANDED_SCALE - SEED_DEFAULT_SCALE) * eased
		local basePosition = floorCFrame.Position:Lerp(liftedCFrame.Position, eased)
		local shake = math.sin(alpha * math.pi * 10) * math.rad(SEED_SHAKE_DEGREES)
		local currentCFrame = CFrame.new(basePosition) * (floorCFrame - floorCFrame.Position) * CFrame.Angles(0, shake, shake * 0.35)
		setScaleAtCFrame(blackClone, currentScale, currentCFrame)
	end)
	liftTween = TweenService:Create(liftAlpha, TweenInfo.new(SEED_LIFT_DURATION + SEED_SHAKE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Value = 1,
	})
	liftTween:Play()
	liftTween.Completed:Wait()
	liftConnection:Disconnect()
	liftAlpha:Destroy()
	if blackClone.Parent then
		blackClone:Destroy()
	end
	if not isCurrentRoll(token) then
		return
	end

	local clone = makeRewardClone(payload, "RollReveal_" .. tostring(payload.rewardId or payload.seedId), SEED_EXPANDED_SCALE, false)
	if not clone then
		return
	end

	clone.Parent = Workspace
	trackActiveReveal(clone, payload.offerId, ownerUserIdFromPayload(payload))
	trackRollEffect(clone, payload.offerId)
	pivotTo(clone, liftedCFrame)
	fadeIn(clone)

	local emitter = attachRarityParticle(clone, Color3.new(1, 1, 1))
	local particleExpiresAt = os.clock() + LOCAL_PARTICLE_LIFETIME
	local targetColor = seedRarityColor(payload)
	task.spawn(tweenParticleColor, emitter, Color3.new(1, 1, 1), targetColor, SEED_POP_IN_DURATION + SEED_POP_OUT_DURATION)
	tweenScaleAtCFrame(clone, liftedCFrame, SEED_EXPANDED_SCALE, SEED_POP_IN_SCALE, SEED_POP_IN_TWEEN)
	tweenScaleAtCFrame(clone, liftedCFrame, SEED_POP_IN_SCALE, SEED_DEFAULT_SCALE, SEED_POP_OUT_TWEEN)
	if not isCurrentRoll(token) then
		if clone.Parent then
			clone:Destroy()
		end
		return
	end
	if Rarities.Get(payload.rarity) and Rarities.Get(payload.rarity).Animated then
		startRainbowParticle(emitter, particleExpiresAt)
	else
		setParticleColor(emitter, targetColor)
	end
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
	trackActiveReveal(clone, payload.offerId, ownerUserIdFromPayload(payload))
	trackRollEffect(clone, payload.offerId)
	local floorCFrame = floorLandingCFrame(clone, crateFloor, 0)
	local liftedCFrame = floorCFrame + Vector3.new(0, MISC_LIFT_HEIGHT, 0)
	setScaleAtCFrame(clone, MISC_START_SCALE, floorCFrame)
	fadeIn(clone)

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

local function showPublicOffer(payload)
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
	trackActiveReveal(clone, payload.offerId, ownerUserIdFromPayload(payload))
	trackRollEffect(clone, payload.offerId)
	local liftHeight = payload.category == RollRewards.Categories.Seed and SEED_LIFT_HEIGHT or MISC_LIFT_HEIGHT
	local baseCFrame = floorLandingCFrame(clone, crateFloor, liftHeight)
	pivotTo(clone, baseCFrame)
	fadeIn(clone)
	setRevealParticlesEnabled(clone, false)
	addRevealBillboard(clone, payload)
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

	local endCFrame = floorLandingCFrame(crate, crateFloor, 0)
	local startCFrame = endCFrame + Vector3.new(0, CRATE_START_HEIGHT, 0)
	pivotTo(crate, startCFrame)
	fadeIn(crate)

	if not playSwayFallTween(crate, startCFrame, endCFrame, token) then
		return
	end

	breakCrate(crate, crateFloor)
	if crate.Parent then
		crate:Destroy()
	end
	if not isCurrentRoll(token) then
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
	local player = Players.LocalPlayer
	local mouse = player:GetMouse()

	mouse.Button1Down:Connect(function()
		local target = mouse.Target
		if isRollButton(target) then
			pressButton(target, false)
		end
	end)
	mouse.Button1Up:Connect(releasePressedButton)

	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		if prompt.Name == CRATE_ROLL_PROMPT_NAME and prompt.Parent and prompt.Parent:IsA("Attachment") then
			pressButton(prompt.Parent.Parent, true)
		end
	end)

	Remotes.get(Remotes.Names.CrateRollEffect).OnClientEvent:Connect(function(payload)
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
				task.spawn(showPublicOffer, offer)
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
		markButtonUnavailableForRoll(payload.button)
		for _, offer in ipairs(offers) do
			offer.ownerUserId = ownerUserId
			if offer.button == nil then
				offer.button = payload.button
			end
			task.spawn(function()
				playCrateFall(offer, token)
			end)
		end
	end)

	Remotes.get(Remotes.Names.CrateRollPurchaseResult).OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		if payload.success then
			clearActiveReveal(payload.offerId)
			return
		end

		local reveal = activeReveals[payload.offerId]
		local prompt = reveal and reveal:FindFirstChild("RollOfferBuyPrompt", true)
		if prompt and prompt:IsA("ProximityPrompt") then
			prompt:SetAttribute(ROLL_OFFER_PENDING_ATTR, false)
			prompt.Enabled = false
		end
	end)
end

return RollController
