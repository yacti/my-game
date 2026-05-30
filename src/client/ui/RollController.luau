local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rarities = require(Shared:WaitForChild("Rarities"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RollConfig = require(Shared:WaitForChild("RollConfig"))
local State = require(Shared:WaitForChild("State"))

local RollController = {}

local CRATE_START_HEIGHT = RollConfig.Crate.StartHeight
local CRATE_FALL_DURATION = RollConfig.Crate.FallDuration
local CRATE_SWAY_AMPLITUDE = RollConfig.Crate.SwayAmplitude
local CRATE_TILT_DEGREES = RollConfig.Crate.TiltDegrees
local IMPACT_CHUNK_COUNT = RollConfig.Crate.ImpactChunkCount
local IMPACT_CHUNK_SIZE = RollConfig.Crate.ImpactChunkSize
local IMPACT_CHUNK_LIFETIME = RollConfig.Crate.ImpactChunkLifetime
local IMPACT_CHUNK_FADE_DURATION = RollConfig.Crate.ImpactChunkFadeDuration
local REVEAL_SCALE = RollConfig.Reveal.InitialScale
local REVEAL_FINAL_SCALE = RollConfig.Reveal.FinalScale
local FLICKER_COUNT = RollConfig.Reveal.FlickerCount
local FLICKER_START_SCALE = RollConfig.Reveal.FlickerStartScale
local FLICKER_END_SCALE = RollConfig.Reveal.FlickerEndScale
local OFFER_VISIBLE_SECONDS = RollConfig.Reveal.OfferVisibleSeconds
local BUY_PROMPT_DISTANCE = RollConfig.Reveal.BuyPromptDistance
local OFFER_ANCHOR_TOP_OFFSET = RollConfig.Reveal.OfferAnchorTopOffset
local BUTTON_PRESS_DURATION = RollConfig.Button.PressDuration
local BUTTON_RELEASE_DURATION = RollConfig.Button.ReleaseDuration
local BUTTON_UNAVAILABLE_COLOR = RollConfig.Button.UnavailableColor
local ROLL_BUTTON_UNAVAILABLE_ATTR = "RollButtonUnavailable"
local CRATE_ROLL_PROMPT_NAME = "__LocalPrompt_CrateRoll"

local CRATE_FALL_TWEEN = TweenInfo.new(CRATE_FALL_DURATION, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)
local POP_TWEEN = TweenInfo.new(RollConfig.Reveal.PopDuration, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local activeRollToken = 0
local activeReveals = {}
local activeRollEffectsByOfferId = {}
local pressedButton = nil
local buttonOriginalCFrames = setmetatable({}, { __mode = "k" })
local buttonOriginalColors = setmetatable({}, { __mode = "k" })
local unavailableButtons = setmetatable({}, { __mode = "k" })
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

local function findFeedTemplate(feedType)
	local root = ReplicatedStorage:FindFirstChild("FeedMachines")
	if not root then
		return nil
	end
	for _, instance in ipairs(root:GetDescendants()) do
		if (instance:IsA("BasePart") or instance:IsA("Model")) and instance:GetAttribute(State.Feed.Type) == feedType then
			return instance
		end
	end
	return nil
end

local function crateTemplate(name)
	local crates = ReplicatedStorage:FindFirstChild("Crates")
	local template = crates and crates:FindFirstChild(name)
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end
	return nil
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
end

local function clearRollEffects()
	clearActiveReveal()
end

local function formatPrice(price)
	local amount = tonumber(price) or 0
	return "$" .. tostring(math.max(math.floor(amount), 0))
end

local function addLine(parent, order, text, color, heightScale)
	local label = Instance.new("TextLabel")
	label.Name = "Line" .. tostring(order)
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, heightScale or 0.25, 0)
	label.LayoutOrder = order
	label.Font = Enum.Font.GothamBold
	label.Text = text
	label.TextColor3 = color or Color3.new(1, 1, 1)
	label.TextScaled = true
	label.TextStrokeTransparency = 0.35
	label.Parent = parent
	return label
end

local function addRevealBillboard(model, payload)
	local anchor = offerAttachment(model)
	if not anchor then
		return
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "RollRevealBillboard"
	billboard.Adornee = anchor
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(200, 86)
	billboard.StudsOffsetWorldSpace = Vector3.zero

	local frame = Instance.new("Frame")
	frame.Name = "Card"
	frame.BackgroundColor3 = Color3.fromRGB(12, 12, 12)
	frame.BackgroundTransparency = 0.2
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromScale(1, 1)
	frame.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 1)
	layout.Parent = frame

	local rarityColor = Rarities.ColorFor(payload.rarity, os.clock()) or Color3.new(1, 1, 1)
	addLine(frame, 1, tostring(payload.displayName or payload.feedType or "Feed Machine"), Color3.new(1, 1, 1), 0.26)
	addLine(frame, 2, "Price: " .. formatPrice(payload.price), Color3.fromRGB(120, 255, 120), 0.24)
	addLine(frame, 3, "Chance: " .. tostring(payload.rngChanceText or ("1 in " .. tostring(payload.chanceN or "?"))), Color3.fromRGB(210, 230, 255), 0.24)
	addLine(frame, 4, "Rarity: " .. tostring(payload.rarity or "Unknown"), rarityColor, 0.24)

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

local function scaleOnFloor(clone, scale, crateFloor)
	scaleClone(clone, scale)
	pivotTo(clone, floorLandingCFrame(clone, crateFloor, 0))
end

local function tweenScaleOnFloor(clone, crateFloor, fromScale, toScale, tweenInfo)
	scaleOnFloor(clone, fromScale, crateFloor)

	local scaleValue = Instance.new("NumberValue")
	scaleValue.Value = fromScale
	local connection = scaleValue:GetPropertyChangedSignal("Value"):Connect(function()
		if clone.Parent then
			scaleOnFloor(clone, scaleValue.Value, crateFloor)
		end
	end)
	local tween = TweenService:Create(scaleValue, tweenInfo, {
		Value = toScale,
	})
	tween:Play()
	tween.Completed:Wait()
	connection:Disconnect()
	scaleValue:Destroy()
	if clone.Parent then
		scaleOnFloor(clone, toScale, crateFloor)
	end
end

local function playImpactChunks(crateFloor, offerId)
	local origin = crateFloor.Position + crateFloor.CFrame.UpVector * (crateFloor.Size.Y * 0.5 + 0.5)
	for _ = 1, IMPACT_CHUNK_COUNT do
		local angle = rng:NextNumber(0, math.pi * 2)
		local outward = crateFloor.CFrame.RightVector * math.cos(angle) + crateFloor.CFrame.LookVector * math.sin(angle)
		local spawnOffset = outward * rng:NextNumber(0.5, 3.5)
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
		trackRollEffect(chunk, offerId)

		local horizontal = outward * rng:NextNumber(5, 11)
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

local function breakCrate(crate, crateFloor, offerId)
	playImpactChunks(crateFloor, offerId)
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

local function makeFeedClone(feedType, name, blackNeon, scale)
	local template = findFeedTemplate(feedType)
	if not template then
		return nil
	end

	local clone = template:Clone()
	clone.Name = name or ("RollPreview_" .. tostring(feedType))
	prepareEffect(clone)
	scaleClone(clone, scale or REVEAL_SCALE)
	if blackNeon then
		setBlackNeon(clone)
	end
	return clone
end

local function addPurchasePrompt(model, payload)
	local anchor = offerAttachment(model)
	if not anchor then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "RollOfferBuyPrompt"
	prompt.ActionText = "Buy " .. formatPrice(payload.price)
	prompt.ObjectText = tostring(payload.displayName or payload.feedType or "Feed Machine")
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = BUY_PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor
	prompt.Triggered:Connect(function()
		if activeReveals[payload.offerId] == nil then
			return
		end
		prompt.Enabled = false
		Remotes.get(Remotes.Names.CrateRollPurchaseRequest):FireServer(payload.offerId)
	end)
end

local function previewFeedTypes(payload)
	local types = {}
	if type(payload.previewFeedTypes) == "table" then
		for _, feedType in ipairs(payload.previewFeedTypes) do
			if type(feedType) == "string" and feedType ~= "" then
				types[#types + 1] = feedType
			end
		end
	end
	if #types == 0 and type(payload.feedType) == "string" then
		types[1] = payload.feedType
	end
	return types
end

local function flickerStepDuration(index, count)
	return RollConfig.FlickerStepDuration(index, count)
end

local function playRollingPreview(payload, crateFloor, token)
	local types = previewFeedTypes(payload)
	if #types == 0 then
		return isCurrentRoll(token)
	end
	local count = FLICKER_COUNT
	for index = 1, count - 1 do
		if not isCurrentRoll(token) then
			return false
		end
		local duration = flickerStepDuration(index, count)
		local feedType = types[((index - 1) % #types) + 1]
		local clone = makeFeedClone(feedType, "RollFlicker_" .. tostring(feedType), true, FLICKER_START_SCALE)
		if clone then
			clone.Parent = Workspace
			trackRollEffect(clone, payload.offerId)
			local base = floorLandingCFrame(clone, crateFloor, 0)
			local angle = math.rad((index % 2 == 0) and -18 or 18)
			pivotTo(clone, base * CFrame.Angles(0, angle, 0))
			tweenScaleOnFloor(clone, crateFloor, FLICKER_START_SCALE, FLICKER_END_SCALE, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out))
			if clone.Parent then
				clone:Destroy()
			end
			if not isCurrentRoll(token) then
				return false
			end
		else
			task.wait(duration)
			if not isCurrentRoll(token) then
				return false
			end
		end
	end
	return true
end

local function revealFeedMachine(payload, crateFloor, token)
	if not isCurrentRoll(token) then
		return
	end
	clearActiveReveal(payload.offerId)

	local blackClone = makeFeedClone(payload.feedType, "RollFinalBlack_" .. tostring(payload.feedType), true, FLICKER_START_SCALE)
	if blackClone then
		blackClone.Parent = Workspace
		trackRollEffect(blackClone, payload.offerId)
		local base = floorLandingCFrame(blackClone, crateFloor, 0)
		pivotTo(blackClone, base * CFrame.Angles(0, math.rad(-25), 0))
		tweenScaleOnFloor(blackClone, crateFloor, FLICKER_START_SCALE, FLICKER_END_SCALE, TweenInfo.new(
			flickerStepDuration(FLICKER_COUNT, FLICKER_COUNT),
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		))
		if blackClone.Parent then
			blackClone:Destroy()
		end
		if not isCurrentRoll(token) then
			return
		end
	else
		task.wait(flickerStepDuration(FLICKER_COUNT, FLICKER_COUNT))
		if not isCurrentRoll(token) then
			return
		end
	end

	local clone = makeFeedClone(payload.feedType, "RollReveal_" .. tostring(payload.feedType), false, FLICKER_END_SCALE)
	if not clone then
		return
	end

	clone.Parent = Workspace
	activeReveals[payload.offerId] = clone
	trackRollEffect(clone, payload.offerId)

	local base = floorLandingCFrame(clone, crateFloor, 0)
	pivotTo(clone, base)
	fadeIn(clone)
	tweenScaleOnFloor(clone, crateFloor, FLICKER_END_SCALE, REVEAL_FINAL_SCALE, POP_TWEEN)
	if not isCurrentRoll(token) then
		if clone.Parent then
			clone:Destroy()
		end
		return
	end
	addRevealBillboard(clone, payload)
	addPurchasePrompt(clone, payload)

	task.delay(OFFER_VISIBLE_SECONDS, function()
		clearActiveReveal(payload.offerId)
	end)
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

	breakCrate(crate, crateFloor, payload.offerId)
	if crate.Parent then
		crate:Destroy()
	end
	if not isCurrentRoll(token) then
		return
	end

	if playRollingPreview(payload, crateFloor, token) then
		revealFeedMachine(payload, crateFloor, token)
	end
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
		if #offers == 0 then
			return
		end

		activeRollToken += 1
		local token = activeRollToken
		clearRollEffects()
		markButtonUnavailableForRoll(payload.button)
		for _, offer in ipairs(offers) do
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
			prompt.Enabled = true
		end
	end)
end

return RollController
