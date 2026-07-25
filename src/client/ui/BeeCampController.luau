-- Bee event camp client (Workspace.Map.BeeEvent). Everything here is
-- per-player and cosmetic: the Jar's Fill part and Amount billboard track the
-- local player's replicated deposit progress (profile.Data.BeeEvent via
-- PlayerStateStore), the Jar prompt fires BeeDepositRequest, the Beekeeper
-- rotates typewriter dialogue lines with floating seed previews, the
-- NextBeeEvent hive sign counts down to the top of the hour, and the nine
-- BeeFace models on the honeycomb wink at random while the event is
-- inactive, fading away while the swarm is out (driven by the replicated
-- GameEvents.Active records so it also works for dev-command events). Map
-- UI/parts are Studio-authored; anything missing warns and is skipped.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BeeEvent = require(Shared:WaitForChild("BeeEvent"))
local Food = require(Shared:WaitForChild("Food"))
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local Mutations = require(Shared:WaitForChild("Mutations"))
local Rarities = require(Shared:WaitForChild("Rarities"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local State = require(Shared:WaitForChild("State"))

local BillboardGuiTemplates = require(script.Parent:WaitForChild("BillboardGuiTemplates"))
local LocalPrompts = require(script.Parent:WaitForChild("LocalPrompts"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local BeeCampController = {}

local WAIT_SECONDS = 15
local PROMPT_DISTANCE = 10
local PROMPT_ATTACHMENT_NAME = "__LocalPrompt_BeeCampAttachment"
local FILL_TWEEN_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COUNTDOWN_STEP_SECONDS = 0.5
local TYPE_SECONDS_PER_GRAPHEME = 0.04
local MAX_TYPE_SECONDS = 3
local RESULT_TIMEOUT_SECONDS = 5
local DIALOGUE_TIMEOUT_SECONDS = 10
local DIALOGUE_LINE_COUNT = 3
local SEED_PREVIEW_DISTANCE_STUDS = 4
local SEED_PREVIEW_HEIGHT_STUDS = -1.5
local SEED_PREVIEW_REVOLUTION_SECONDS = 3
local SEED_PREVIEW_UI_SCALE = 0.5
local TILT_FACING_SECONDS = 3
local TILT_TURN_SECONDS = 0.4
local TILT_RADIANS = math.rad(18)
local TILT_MAX_TURN_RADIANS = math.rad(60)
local IDLE_ANIMATION_ATTR = "IdleAnimationId"
local THINKING_ANIMATION_ATTR = "ThinkingAnimationId"
local ANIMATION_ID_PATTERN = "^rbxassetid://%d+$"
-- Ambient winks: each BeeFace blinks one eye roughly every half minute.
local WINK_MIN_GAP_SECONDS = 22
local WINK_MAX_GAP_SECONDS = 38
local WINK_SQUISH_SCALE = 0.15
local WINK_CLOSE_SECONDS = 0.12
local WINK_OPEN_SECONDS = 0.15
local FACE_FADE_SECONDS = 1.5

local player = Players.LocalPlayer
local requestRemote = Remotes.get(Remotes.Names.BeeDepositRequest)
local resultRemote = Remotes.get(Remotes.Names.BeeDepositResult)

local jarRecord = nil -- { glass, fill, maxSize, bottomY, amountLabel, prompt, initialized }
local nextRequestId = 0
local pendingRequestId = nil
local winkRng = Random.new()
local faceRecords = {} -- { model, parts = {BasePart...}, eyes = {{part, restSize, restCFrame}} }
local facesHidden = false

local function serverNow()
	return Workspace:GetServerTimeNow()
end

local function beeState()
	return PlayerStateStore.Get(PlayerStateStore.Fields.BeeEvent)
end

local function currentTier()
	local state = beeState()
	return BeeEvent.NormalizeTier(state and state.Tier)
end

local function depositCount()
	local state = beeState()
	local count = state and tonumber(state.Deposits) or 0
	return math.max(math.floor(count or 0), 0)
end

local function requiredDeposits()
	return BeeEvent.RequiredFor(currentTier()) or 0
end

local function jarFilled()
	return depositCount() >= requiredDeposits()
end

local function hasPollinatedFoodEquipped()
	local character = player.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	if not tool or tool:GetAttribute(State.Food.Id) == nil then
		return false
	end
	return Mutations.Contains(Food.MutationIdsOf(tool), BeeEvent.MutationId)
end

-- The Jar's Fill mesh is authored at its full size; the bottom face stays put
-- while the height scales with deposit progress (crate-fill pattern).
local function applyFill(record, ratio, animate)
	local fill = record.fill
	local targetSize = Vector3.new(record.maxSize.X, record.maxSize.Y * ratio, record.maxSize.Z)
	local targetPosition = Vector3.new(fill.Position.X, record.bottomY + targetSize.Y / 2, fill.Position.Z)
	local targetTransparency = ratio > 0 and 0 or 1
	if animate then
		TweenService:Create(fill, FILL_TWEEN_INFO, {
			Size = targetSize,
			Position = targetPosition,
			Transparency = targetTransparency,
		}):Play()
	else
		fill.Size = targetSize
		fill.Position = targetPosition
		fill.Transparency = targetTransparency
	end
end

local function refreshJar()
	local record = jarRecord
	if not record then
		return
	end
	local required = requiredDeposits()
	local count = math.min(depositCount(), required)
	local ratio = required > 0 and count / required or 0
	applyFill(record, ratio, record.initialized == true)
	record.initialized = true
	if record.amountLabel then
		record.amountLabel.Text = string.format("%d/%d", count, required)
	end
end

local function jarAvailability(prompt)
	if PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true or beeState() == nil then
		return false
	end
	if pendingRequestId ~= nil then
		return false
	end
	-- A full jar means a reward grant was blocked (inventory full); the
	-- prompt retries the grant server-side.
	if jarFilled() then
		prompt.ActionText = "Collect Bee Reward"
		return true
	end
	if not hasPollinatedFoodEquipped() then
		return false
	end
	prompt.ActionText = "Deposit Pollinated Food"
	return true
end

local function sendDeposit()
	if pendingRequestId ~= nil then
		return
	end
	nextRequestId += 1
	pendingRequestId = nextRequestId
	requestRemote:FireServer(pendingRequestId)
	local sentRequestId = pendingRequestId
	task.delay(RESULT_TIMEOUT_SECONDS, function()
		if pendingRequestId == sentRequestId then
			pendingRequestId = nil
		end
	end)
end

local function promptAttachmentFor(part)
	local attachment = part:FindFirstChild(PROMPT_ATTACHMENT_NAME)
	if not (attachment and attachment:IsA("Attachment")) then
		attachment = Instance.new("Attachment")
		attachment.Name = PROMPT_ATTACHMENT_NAME
		attachment.Parent = part
	end
	return attachment
end

local function makePrompt(part, actionText, theme)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "__LocalPrompt_BeeCamp"
	prompt.ActionText = actionText
	prompt.ObjectText = ""
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt:SetAttribute("Theme", theme)
	prompt.Parent = promptAttachmentFor(part)
	return prompt
end

-- The camp models should be ModelStreamingMode.Persistent, but they can
-- still arrive after client boot — wait instead of FindFirstChild.
local function bindJar(activeFolder)
	local jar = activeFolder:WaitForChild(BeeEvent.JarName, WAIT_SECONDS)
	local glass = jar and jar:WaitForChild(BeeEvent.JarGlassName, WAIT_SECONDS)
	local fill = jar and jar:WaitForChild("Fill", WAIT_SECONDS)
	if not (glass and glass:IsA("BasePart") and fill and fill:IsA("BasePart")) then
		warn("[BeeCampController] Missing Jar parts — skipping")
		return
	end

	local billboard = glass:FindFirstChild(BeeEvent.JarBillboardName, true)
	local amountLabel = billboard and billboard:FindFirstChild("Amount", true)
	if not (amountLabel and amountLabel:IsA("TextLabel")) then
		warn("[BeeCampController] Missing Jar " .. BeeEvent.JarBillboardName .. " Amount label")
		amountLabel = nil
	end

	local record = {
		glass = glass,
		fill = fill,
		maxSize = fill.Size,
		bottomY = fill.Position.Y - fill.Size.Y / 2,
		amountLabel = amountLabel,
		initialized = false,
	}
	jarRecord = record

	local prompt = makePrompt(glass, "Deposit Pollinated Food", "TreeGroundPickup")
	record.prompt = prompt
	LocalPrompts.RegisterExternalPrompt(prompt, function()
		return jarAvailability(prompt)
	end)
	RuntimeGuard.Connect(prompt.Triggered, "BeeCampController.JarTriggered", function()
		if jarAvailability(prompt) then
			sendDeposit()
		end
	end)
end

---------------------------------------------------------------------------
-- BeeFace winks + active-window fades
---------------------------------------------------------------------------

local function bindBeeFaces(activeFolder)
	local inactiveFolder = activeFolder:WaitForChild(BeeEvent.EventInactiveName, WAIT_SECONDS)
	if not inactiveFolder then
		warn("[BeeCampController] Missing " .. BeeEvent.EventInactiveName .. " folder — skipping BeeFaces")
		return
	end
	for _, model in ipairs(inactiveFolder:GetChildren()) do
		if model.Name == BeeEvent.BeeFaceName then
			local record = { model = model, parts = {}, eyes = {} }
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("BasePart") then
					record.parts[#record.parts + 1] = part
				end
			end
			local animated = model:FindFirstChild("Animated")
			for _, eyeName in ipairs({ "Eye1", "Eye2" }) do
				local eye = animated and animated:FindFirstChild(eyeName)
				if eye and eye:IsA("BasePart") then
					record.eyes[#record.eyes + 1] = {
						part = eye,
						restSize = eye.Size,
						restCFrame = eye.CFrame,
					}
				end
			end
			faceRecords[#faceRecords + 1] = record
		end
	end
	if #faceRecords == 0 then
		warn("[BeeCampController] No " .. BeeEvent.BeeFaceName .. " models found")
		return
	end

	-- One wink loop per face: a randomized 22-38s heartbeat where either eye
	-- squishes shut and pops back open. Paused while the faces are faded out
	-- during the active window.
	for _, record in ipairs(faceRecords) do
		task.spawn(function()
			task.wait(winkRng:NextNumber(1, WINK_MAX_GAP_SECONDS))
			while record.model.Parent do
				if not facesHidden and #record.eyes > 0 then
					local eye = record.eyes[winkRng:NextInteger(1, #record.eyes)]
					RuntimeGuard.Run("BeeCampController.Wink", function()
						-- Squish toward the eye's own center; never to zero
						-- size (engine zero-size text/layout hazards aside,
						-- unions at zero scale render poorly).
						local squishedSize = Vector3.new(
							eye.restSize.X,
							math.max(eye.restSize.Y * WINK_SQUISH_SCALE, 0.05),
							eye.restSize.Z
						)
						local close = TweenService:Create(eye.part, TweenInfo.new(WINK_CLOSE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
							Size = squishedSize,
						})
						close:Play()
						close.Completed:Wait()
						local open = TweenService:Create(eye.part, TweenInfo.new(WINK_OPEN_SECONDS, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
							Size = eye.restSize,
						})
						open:Play()
						open.Completed:Wait()
						eye.part.Size = eye.restSize
						eye.part.CFrame = eye.restCFrame
					end)
				end
				task.wait(winkRng:NextNumber(WINK_MIN_GAP_SECONDS, WINK_MAX_GAP_SECONDS))
			end
		end)
	end
end

local function setFacesHidden(hidden)
	if facesHidden == hidden then
		return
	end
	facesHidden = hidden
	for _, record in ipairs(faceRecords) do
		for _, part in ipairs(record.parts) do
			TweenService:Create(part, TweenInfo.new(FACE_FADE_SECONDS), {
				Transparency = hidden and 1 or 0,
			}):Play()
		end
	end
end

-- The replicated GameEvents.Active records are the single source of truth for
-- "the bees are out" (covers scheduled, manual, and dev-command events).
-- Polled from the timer loop instead of ChildAdded/Removed because every
-- publish rewrites the record folders.
local function beeEventActive()
	local runtime = ReplicatedStorage:FindFirstChild(GameEvents.RuntimeFolderName)
	local active = runtime and runtime:FindFirstChild(GameEvents.ActiveFolderName)
	if not active then
		return false
	end
	local now = serverNow()
	for _, record in ipairs(active:GetChildren()) do
		if record:GetAttribute(State.GameEvent.EventId) == GameEvents.Ids.Bee then
			local startsAt = tonumber(record:GetAttribute(State.GameEvent.StartsAt))
			local endsAt = tonumber(record:GetAttribute(State.GameEvent.EndsAt))
			if startsAt and endsAt and now >= startsAt and now < endsAt then
				return true
			end
		end
	end
	return false
end

---------------------------------------------------------------------------
-- Beekeeper dialogue
---------------------------------------------------------------------------

local function playTypewriter(textLabel, text)
	textLabel.Text = text
	local graphemes = utf8.len(text) or #text
	if graphemes <= 0 then
		return
	end
	textLabel.MaxVisibleGraphemes = 0
	local seconds = math.min(graphemes * TYPE_SECONDS_PER_GRAPHEME, MAX_TYPE_SECONDS)
	TweenService:Create(textLabel, TweenInfo.new(seconds, Enum.EasingStyle.Linear), {
		MaxVisibleGraphemes = graphemes,
	}):Play()
end

local function loadTrack(animator, animationId)
	if not animator or type(animationId) ~= "string" or not animationId:match(ANIMATION_ID_PATTERN) then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		warn("[BeeCampController] Failed to load animation " .. animationId)
		return nil
	end
	return track
end

local function setupBeekeeper(activeFolder)
	local outer = activeFolder:WaitForChild(BeeEvent.BeekeeperName, WAIT_SECONDS)
	local rig = outer and outer:WaitForChild(BeeEvent.BeekeeperName, WAIT_SECONDS)
	local humanoid = rig and rig:WaitForChild("Humanoid", WAIT_SECONDS)
	local torso = rig and rig:WaitForChild("Torso", WAIT_SECONDS)
	if not (humanoid and torso) then
		warn("[BeeCampController] Missing Beekeeper rig — skipping")
		return
	end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	local dialogueGui = torso:WaitForChild(BeeEvent.BeekeeperDialogueGuiName, WAIT_SECONDS)
	local dialogueFrame = dialogueGui and dialogueGui:FindFirstChild("Frame")
	local dialogueLabel = dialogueFrame and dialogueFrame:FindFirstChild("Dialogue")
	if not (dialogueLabel and dialogueLabel:IsA("TextLabel")) then
		warn("[BeeCampController] Missing " .. BeeEvent.BeekeeperDialogueGuiName .. " label")
		dialogueLabel = nil
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	local idleTrack = loadTrack(animator, rig:GetAttribute(IDLE_ANIMATION_ATTR))
	if idleTrack then
		idleTrack.Looped = true
		idleTrack.Priority = Enum.AnimationPriority.Idle
		idleTrack:Play()
	end
	local thinkingTrack = loadTrack(animator, rig:GetAttribute(THINKING_ANIMATION_ATTR))
	if thinkingTrack then
		thinkingTrack.Priority = Enum.AnimationPriority.Action
	end

	-- No Roblox-made "thinking" animation exists for R6 rigs, so without a
	-- ThinkingAnimationId attribute the gesture is procedural. Unlike the
	-- Scientist (anchored head parts), the Beekeeper's Head hangs off a
	-- Motor6D Neck — so the turn/tilt drives Neck.C0 in torso space:
	-- pre-multiplying CFrame.Angles(0, yaw, 0) yaws the head about the
	-- torso's up axis, CFrame.Angles(0, 0, roll) tilts it sideways.
	local neck = torso:FindFirstChild("Neck")
	if not (neck and neck:IsA("Motor6D")) then
		neck = nil
		warn("[BeeCampController] Beekeeper Torso has no Neck Motor6D; thinking tilt skipped")
	end
	local neckRestC0 = neck and neck.C0 or nil

	local tiltToken = 0
	local function playThinking()
		if thinkingTrack then
			thinkingTrack:Play()
			return
		end
		if not neck then
			return
		end
		tiltToken += 1
		local token = tiltToken

		-- Face the local player, but never beyond TILT_MAX_TURN_RADIANS —
		-- a player standing behind him gets a partial turn, not a
		-- 180-degree head spin.
		local targetYaw = 0
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			local direction = torso.CFrame:VectorToObjectSpace(root.Position - torso.Position)
			direction = Vector3.new(direction.X, 0, direction.Z)
			if direction.Magnitude > 0.05 then
				direction = direction.Unit
				targetYaw = math.clamp(math.atan2(-direction.X, -direction.Z), -TILT_MAX_TURN_RADIANS, TILT_MAX_TURN_RADIANS)
			end
		end

		local function neckC0For(alpha)
			return CFrame.Angles(0, targetYaw * alpha, 0)
				* CFrame.Angles(0, 0, TILT_RADIANS * alpha)
				* neckRestC0
		end

		task.spawn(function()
			local startedAt = os.clock()
			local totalSeconds = TILT_FACING_SECONDS + TILT_TURN_SECONDS
			while tiltToken == token and neck.Parent do
				local elapsed = os.clock() - startedAt
				if elapsed >= totalSeconds then
					break
				end
				local alpha
				if elapsed < TILT_TURN_SECONDS then
					alpha = TweenService:GetValue(elapsed / TILT_TURN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				elseif elapsed < TILT_FACING_SECONDS then
					alpha = 1
				else
					alpha = 1 - TweenService:GetValue((elapsed - TILT_FACING_SECONDS) / TILT_TURN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				end
				neck.C0 = neckC0For(alpha)
				RunService.Heartbeat:Wait()
			end
			if tiltToken == token and neck.Parent then
				neck.C0 = neckRestC0
			end
		end)
	end

	-- Floating reward-seed preview shown alongside the reward dialogue
	-- lines: the seed template spinning in front of the Beekeeper with the
	-- SeedRoll billboard card from the crate-roll reveal.
	local activePreview = nil
	local function clearSeedPreview()
		if not activePreview then
			return
		end
		if activePreview.connection then
			activePreview.connection:Disconnect()
		end
		if activePreview.model then
			activePreview.model:Destroy()
		end
		activePreview = nil
	end

	local function showSeedPreview(rewardSeedId)
		clearSeedPreview()
		local template = Seeds.GetTemplate(rewardSeedId)
		if not template then
			warn("[BeeCampController] Missing seed template " .. tostring(rewardSeedId))
			return
		end
		local clone = template:Clone()
		clone.Name = "BeeCampSeedPreview"
		for _, part in ipairs(clone:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = false
				part.CanTouch = false
				part.CanQuery = false
			end
		end
		if clone:IsA("BasePart") then
			clone.Anchored = true
			clone.CanCollide = false
			clone.CanTouch = false
			clone.CanQuery = false
		end
		local base = torso.CFrame * CFrame.new(0, SEED_PREVIEW_HEIGHT_STUDS, -SEED_PREVIEW_DISTANCE_STUDS)
		clone:PivotTo(base)
		clone.Parent = Workspace

		local animatedRarityLabel = nil
		local animatedRarity = nil
		local billboardTemplate = BillboardGuiTemplates.Find("SeedRoll")
		if billboardTemplate and billboardTemplate:IsA("BillboardGui") then
			local billboard = billboardTemplate:Clone()
			billboard.Name = "BeeCampSeedPreviewBillboard"
			billboard.Adornee = clone:IsA("Model") and (clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)) or clone
			billboard.AlwaysOnTop = true
			billboard.Size = UDim2.new(
				billboard.Size.X.Scale * SEED_PREVIEW_UI_SCALE,
				billboard.Size.X.Offset * SEED_PREVIEW_UI_SCALE,
				billboard.Size.Y.Scale * SEED_PREVIEW_UI_SCALE,
				billboard.Size.Y.Offset * SEED_PREVIEW_UI_SCALE
			)
			local card = billboard:FindFirstChild("Card")
			if card then
				local rarity = Seeds.RarityFor(rewardSeedId)
				local nameLabel = card:FindFirstChild("NameLabel")
				local priceLabel = card:FindFirstChild("PriceLabel")
				local chanceLabel = card:FindFirstChild("ChanceLabel")
				local rarityLabel = card:FindFirstChild("RarityLabel")
				if nameLabel then
					UiEffects.SetTextStack(nameLabel, Seeds.DisplayNameFor(rewardSeedId))
				end
				if priceLabel then
					-- Bee rewards are granted directly, never bought — no
					-- price line on the preview card.
					priceLabel.Visible = false
				end
				if chanceLabel then
					UiEffects.SetTextStack(chanceLabel, "Event Reward")
				end
				if rarityLabel then
					UiEffects.SetTextStack(rarityLabel, tostring(rarity or "Unknown"))
					local rarityColor = Rarities.TextColorFor(rarity, os.clock())
					if rarityColor then
						rarityLabel.TextColor3 = rarityColor
					end
					-- Animated rarities cycle their color, so a one-shot set
					-- would freeze them; keep them live from the spin loop.
					local definition = Rarities.Get(rarity)
					if definition and definition.Animated then
						animatedRarityLabel = rarityLabel
						animatedRarity = rarity
					end
				end
			end
			billboard.Parent = billboard.Adornee
		else
			warn("[BeeCampController] Missing " .. BillboardGuiTemplates.Path("SeedRoll") .. " BillboardGui")
		end

		local angle = 0
		local connection = RuntimeGuard.Connect(RunService.Heartbeat, "BeeCampController.SeedPreviewSpin", function(deltaTime)
			angle += deltaTime * math.pi * 2 / SEED_PREVIEW_REVOLUTION_SECONDS
			clone:PivotTo(base * CFrame.Angles(0, angle, 0))
			if animatedRarityLabel and animatedRarityLabel.Parent then
				local color = Rarities.TextColorFor(animatedRarity, os.clock())
				if color then
					animatedRarityLabel.TextColor3 = color
				end
			end
		end)
		activePreview = { model = clone, connection = connection }
	end

	-- Rotates reward line -> flavour line -> next-tier tease, one per prompt
	-- (the Scientist's storm-forecast line has no bee equivalent -- there is
	-- only one event per hour). The dialogue stays hidden until prompted and
	-- hides again (with the seed preview) DIALOGUE_TIMEOUT_SECONDS after the
	-- last prompt.
	local dialogueToken = 0
	local lineIndex = 0
	local function hideDialogue()
		if dialogueGui then
			dialogueGui.Enabled = false
		end
		clearSeedPreview()
	end

	local function speak()
		playThinking()
		if not dialogueLabel then
			return
		end
		dialogueToken += 1
		local token = dialogueToken
		lineIndex = lineIndex % DIALOGUE_LINE_COUNT + 1
		clearSeedPreview()
		local text
		if lineIndex == 1 then
			local rewardSeedId = BeeEvent.TierConfig(currentTier()).rewardSeedId
			local rewardName = Seeds.DisplayNameFor(rewardSeedId)
			local article = rewardName:match("^[AEIOUaeiou]") and "an" or "a"
			text = string.format("Fill the jar with Pollinated food and receive %s %s!", article, rewardName)
			showSeedPreview(rewardSeedId)
		elseif lineIndex == 2 then
			text = "My bees visit every hour — let them pollinate your crops!"
		else
			-- Tease the tier after the current one; NextTier loops the last
			-- tier back to 1, so the preview always has a reward to show.
			local nextRewardSeedId = BeeEvent.TierConfig(BeeEvent.NextTier(currentTier())).rewardSeedId
			text = "If you finish this task, I have another task for you with this reward!"
			showSeedPreview(nextRewardSeedId)
		end
		if dialogueGui then
			dialogueGui.Enabled = true
		end
		playTypewriter(dialogueLabel, text)
		task.delay(DIALOGUE_TIMEOUT_SECONDS, function()
			if dialogueToken == token then
				hideDialogue()
			end
		end)
	end

	local prompt = makePrompt(torso, "Ask the Beekeeper", "TreeGroundPickup")
	LocalPrompts.RegisterExternalPrompt(prompt, function()
		return PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true
	end)
	RuntimeGuard.Connect(prompt.Triggered, "BeeCampController.BeekeeperTriggered", speak)
end

---------------------------------------------------------------------------
-- Hive timer
---------------------------------------------------------------------------

local function setupHiveTimer()
	local hiveMesh = BeeEvent.FindHiveMesh()
	local timerGui = hiveMesh and hiveMesh:WaitForChild(BeeEvent.HiveTimerGuiName, WAIT_SECONDS)
	local timerFrame = timerGui and timerGui:FindFirstChild("Frame")
	local timerLabel = timerFrame and timerFrame:FindFirstChild("Timer")
	if not (timerLabel and timerLabel:IsA("TextLabel")) then
		warn("[BeeCampController] Missing " .. BeeEvent.HiveTimerGuiName .. " timer label")
		timerLabel = nil
	end
	task.spawn(function()
		while true do
			local active = beeEventActive()
			-- The hive sign and the BeeFace fade share the same source of
			-- truth, so the faces vanish exactly while the sign says the
			-- bees are out.
			setFacesHidden(active)
			if timerLabel then
				if not timerLabel.Parent then
					timerLabel = nil
				elseif active then
					timerLabel.Text = "The bees are out!"
				else
					local now = serverNow()
					timerLabel.Text = "Bees come out in: " .. GameEvents.FormatDuration(BeeEvent.NextEventStart(now) - now)
				end
			end
			task.wait(COUNTDOWN_STEP_SECONDS)
		end
	end)
end

function BeeCampController.start()
	if not BeeEvent.Enabled then
		return
	end
	RuntimeGuard.Connect(resultRemote.OnClientEvent, "BeeCampController.Result", function(payload)
		if type(payload) ~= "table" or payload.requestId ~= pendingRequestId then
			return
		end
		pendingRequestId = nil
		if payload.success == true and payload.code == "deposited" then
			SoundEffects.PlayVaried(SoundEffects.Names.CrateDeposit, {
				parent = jarRecord and jarRecord.glass or nil,
				range = 60,
			})
		end
	end)

	task.spawn(function()
		local map = Workspace:WaitForChild("Map", WAIT_SECONDS)
		local eventFolder = map and map:WaitForChild(BeeEvent.MapFolderName, WAIT_SECONDS)
		local activeFolder = eventFolder and eventFolder:WaitForChild(BeeEvent.ActiveFolderName, WAIT_SECONDS)
		if not activeFolder then
			warn("[BeeCampController] Missing Workspace.Map." .. BeeEvent.MapFolderName .. "." .. BeeEvent.ActiveFolderName .. " — skipping")
			return
		end

		bindJar(activeFolder)
		bindBeeFaces(activeFolder)
		setupBeekeeper(activeFolder)
		setupHiveTimer()

		PlayerStateStore.Observe(PlayerStateStore.Fields.BeeEvent, function()
			refreshJar()
		end)
		refreshJar()
	end)
end

return BeeCampController
