-- StormChaser camp client (Workspace.Map["3HourlyEvent"].Active). Everything
-- here is per-player and cosmetic: crate fill parts tween to the local
-- player's replicated deposit progress (profile.Data.StormChaser via
-- PlayerStateStore), deposit prompts fire StormChaserDepositRequest, the
-- Scientist alternates typewriter dialogue lines and plays idle/thinking
-- animations locally, NextStorm counts down to the next cycle slot, and the
-- RadarDish spins continuously. Map UI/parts are Studio-authored; anything
-- missing warns and is skipped.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local Mutations = require(Shared:WaitForChild("Mutations"))
local Rarities = require(Shared:WaitForChild("Rarities"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local State = require(Shared:WaitForChild("State"))
local StormChaser = require(Shared:WaitForChild("StormChaser"))

local BillboardGuiTemplates = require(script.Parent:WaitForChild("BillboardGuiTemplates"))
local LocalPrompts = require(script.Parent:WaitForChild("LocalPrompts"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local StormChaserController = {}

local WAIT_SECONDS = 15
local PROMPT_DISTANCE = 10
local PROMPT_ATTACHMENT_NAME = "__LocalPrompt_StormChaserAttachment"
local FILL_TWEEN_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RADAR_REVOLUTION_SECONDS = 8
local COUNTDOWN_STEP_SECONDS = 0.5
local TYPE_SECONDS_PER_GRAPHEME = 0.04
local MAX_TYPE_SECONDS = 3
local RESULT_TIMEOUT_SECONDS = 5
local DIALOGUE_TIMEOUT_SECONDS = 10
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

local player = Players.LocalPlayer
local requestRemote = Remotes.get(Remotes.Names.StormChaserDepositRequest)
local resultRemote = Remotes.get(Remotes.Names.StormChaserDepositResult)

local crates = {} -- [mutationId] = { fill, maxSize, bottomY, amountLabel, prompt, initialized }
local nextRequestId = 0
local pendingRequestId = nil

local function serverNow()
	return Workspace:GetServerTimeNow()
end

local function stormState()
	return PlayerStateStore.Get(PlayerStateStore.Fields.StormChaser)
end

local function currentTier()
	local sc = stormState()
	return StormChaser.NormalizeTier(sc and sc.Tier)
end

local function countFor(mutationId)
	local sc = stormState()
	local deposits = sc and sc.Deposits
	local count = type(deposits) == "table" and tonumber(deposits[mutationId]) or 0
	return math.max(math.floor(count or 0), 0)
end

local function requiredFor(mutationId)
	return StormChaser.RequiredFor(currentTier(), mutationId) or 0
end

local function allCratesFilled()
	for _, mutationId in ipairs(StormChaser.CrateMutationIds) do
		if countFor(mutationId) < requiredFor(mutationId) then
			return false
		end
	end
	return true
end

local function hasMatchingFoodEquipped(mutationId)
	local character = player.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	if not tool or tool:GetAttribute(State.Food.Id) == nil then
		return false
	end
	return Mutations.Contains(Food.MutationIdsOf(tool), mutationId)
end

-- Crate fill parts are authored at their full size; the bottom face stays put
-- while the height scales with deposit progress.
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

local function refreshCrates()
	for mutationId, record in pairs(crates) do
		local required = requiredFor(mutationId)
		local count = math.min(countFor(mutationId), required)
		local ratio = required > 0 and count / required or 0
		applyFill(record, ratio, record.initialized == true)
		record.initialized = true
		if record.amountLabel then
			record.amountLabel.Text = string.format("%d/%d", count, required)
		end
	end
end

local function crateAvailability(mutationId, prompt)
	if PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true or stormState() == nil then
		return false
	end
	if pendingRequestId ~= nil then
		return false
	end
	-- Every crate full means a reward grant was blocked (inventory full); the
	-- prompt retries the grant server-side.
	if allCratesFilled() then
		prompt.ActionText = "Collect Storm Reward"
		return true
	end
	if countFor(mutationId) >= requiredFor(mutationId) then
		return false
	end
	if not hasMatchingFoodEquipped(mutationId) then
		return false
	end
	prompt.ActionText = string.format("Deposit %s Food", mutationId)
	return true
end

local function sendDeposit(mutationId)
	if pendingRequestId ~= nil then
		return
	end
	nextRequestId += 1
	pendingRequestId = nextRequestId
	requestRemote:FireServer(pendingRequestId, mutationId)
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
	prompt.Name = "__LocalPrompt_StormChaser"
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

-- The camp models are marked ModelStreamingMode.Persistent, but they can
-- still arrive after client boot — wait instead of FindFirstChild.
local function bindCrate(activeFolder, mutationId)
	local crate = activeFolder:WaitForChild(StormChaser.CrateNames[mutationId], WAIT_SECONDS)
	local body = crate and crate:WaitForChild("CrateBody", WAIT_SECONDS)
	local fill = crate and crate:WaitForChild("Fill", WAIT_SECONDS)
	if not (body and body:IsA("BasePart") and fill and fill:IsA("BasePart")) then
		warn(string.format("[StormChaserController] Missing %s crate parts — skipping", mutationId))
		return
	end

	local billboard = body:FindFirstChildWhichIsA("BillboardGui", true)
	local amountLabel = billboard and billboard:FindFirstChild("Amount", true)
	if not (amountLabel and amountLabel:IsA("TextLabel")) then
		warn(string.format("[StormChaserController] Missing %s crate Amount label", mutationId))
		amountLabel = nil
	end

	local record = {
		body = body,
		fill = fill,
		maxSize = fill.Size,
		bottomY = fill.Position.Y - fill.Size.Y / 2,
		amountLabel = amountLabel,
		initialized = false,
	}
	crates[mutationId] = record

	local prompt = makePrompt(body, string.format("Deposit %s Food", mutationId), "TreeGroundPickup")
	record.prompt = prompt
	LocalPrompts.RegisterExternalPrompt(prompt, function()
		return crateAvailability(mutationId, prompt)
	end)
	RuntimeGuard.Connect(prompt.Triggered, "StormChaserController.CrateTriggered", function()
		if crateAvailability(mutationId, prompt) then
			sendDeposit(mutationId)
		end
	end)
end

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
		warn("[StormChaserController] Failed to load animation " .. animationId)
		return nil
	end
	return track
end

local function setupScientist(activeFolder)
	local scientist = activeFolder:WaitForChild("Scientist", WAIT_SECONDS)
	local humanoid = scientist and scientist:WaitForChild("Humanoid", WAIT_SECONDS)
	local torso = scientist and scientist:WaitForChild("Torso", WAIT_SECONDS)
	if not (humanoid and torso) then
		warn("[StormChaserController] Missing Scientist rig — skipping")
		return
	end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	local dialogueGui = torso:WaitForChild("ScientistDialogue", WAIT_SECONDS)
	local dialogueFrame = dialogueGui and dialogueGui:FindFirstChild("Frame")
	local dialogueLabel = dialogueFrame and dialogueFrame:FindFirstChild("Dialogue")
	if not (dialogueLabel and dialogueLabel:IsA("TextLabel")) then
		warn("[StormChaserController] Missing ScientistDialogue label")
		dialogueLabel = nil
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	local idleTrack = loadTrack(animator, scientist:GetAttribute(IDLE_ANIMATION_ATTR))
	if idleTrack then
		idleTrack.Looped = true
		idleTrack.Priority = Enum.AnimationPriority.Idle
		idleTrack:Play()
	end
	local thinkingTrack = loadTrack(animator, scientist:GetAttribute(THINKING_ANIMATION_ATTR))
	if thinkingTrack then
		thinkingTrack.Priority = Enum.AnimationPriority.Action
	end

	-- No Roblox-made "thinking" animation exists for R6 rigs (the catalog
	-- Think emote is R15-only), so without a ThinkingAnimationId attribute the
	-- gesture is procedural: turn the head toward the local player with a
	-- curious sideways tilt, hold for TILT_FACING_SECONDS, then return to
	-- rest. The rig has no Neck joint — the Head is anchored, and the
	-- hair/glasses are separate anchored parts, so all three are CFramed
	-- together relative to the head.
	local head = scientist:FindFirstChild("Head")
	local headRestCFrame = head and head:IsA("BasePart") and head.CFrame or nil
	local headMotionParts = {}
	if headRestCFrame then
		headMotionParts[1] = { part = head, offset = CFrame.identity }
		local hair = scientist:FindFirstChild("MadScientistHair")
		if hair and hair:IsA("BasePart") then
			headMotionParts[#headMotionParts + 1] = { part = hair, offset = headRestCFrame:ToObjectSpace(hair.CFrame) }
		end
		local glasses = scientist:FindFirstChild("Round Glasses")
		local glassesHandle = glasses and glasses:FindFirstChild("Handle")
		if glassesHandle and glassesHandle:IsA("BasePart") then
			headMotionParts[#headMotionParts + 1] = { part = glassesHandle, offset = headRestCFrame:ToObjectSpace(glassesHandle.CFrame) }
		end
	end

	local function applyHeadCFrame(cframe)
		for _, entry in ipairs(headMotionParts) do
			entry.part.CFrame = cframe * entry.offset
		end
	end

	local tiltToken = 0
	local function playThinking()
		if thinkingTrack then
			thinkingTrack:Play()
			return
		end
		if not headRestCFrame then
			return
		end
		tiltToken += 1
		local token = tiltToken

		-- Face the local player, but never beyond TILT_MAX_TURN_RADIANS from
		-- the rest pose — a player standing behind him gets a partial turn,
		-- not a 180-degree head spin.
		local facingCFrame = headRestCFrame
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			local toPlayer = root.Position - headRestCFrame.Position
			toPlayer = Vector3.new(toPlayer.X, 0, toPlayer.Z)
			if toPlayer.Magnitude > 0.05 then
				local restLook = headRestCFrame.LookVector
				restLook = Vector3.new(restLook.X, 0, restLook.Z).Unit
				toPlayer = toPlayer.Unit
				local yaw = math.atan2(-toPlayer.X, -toPlayer.Z) - math.atan2(-restLook.X, -restLook.Z)
				if yaw > math.pi then
					yaw -= math.pi * 2
				elseif yaw < -math.pi then
					yaw += math.pi * 2
				end
				yaw = math.clamp(yaw, -TILT_MAX_TURN_RADIANS, TILT_MAX_TURN_RADIANS)
				facingCFrame = headRestCFrame * CFrame.Angles(0, yaw, 0)
			end
		end
		local tiltedCFrame = facingCFrame * CFrame.Angles(0, 0, TILT_RADIANS)

		task.spawn(function()
			local startedAt = os.clock()
			local totalSeconds = TILT_FACING_SECONDS + TILT_TURN_SECONDS
			while tiltToken == token do
				local elapsed = os.clock() - startedAt
				if elapsed >= totalSeconds then
					break
				end
				local cframe
				if elapsed < TILT_TURN_SECONDS then
					local alpha = TweenService:GetValue(elapsed / TILT_TURN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
					cframe = headRestCFrame:Lerp(tiltedCFrame, alpha)
				elseif elapsed < TILT_FACING_SECONDS then
					cframe = tiltedCFrame
				else
					local alpha = TweenService:GetValue((elapsed - TILT_FACING_SECONDS) / TILT_TURN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
					cframe = tiltedCFrame:Lerp(headRestCFrame, alpha)
				end
				applyHeadCFrame(cframe)
				RunService.Heartbeat:Wait()
			end
			if tiltToken == token then
				applyHeadCFrame(headRestCFrame)
			end
		end)
	end

	-- Floating reward-seed preview shown alongside the reward dialogue line:
	-- the seed template spinning 2 studs in front of the Scientist with the
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
			warn("[StormChaserController] Missing seed template " .. tostring(rewardSeedId))
			return
		end
		local clone = template:Clone()
		clone.Name = "StormChaserSeedPreview"
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
			billboard.Name = "StormChaserSeedPreviewBillboard"
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
					-- StormChaser rewards are granted directly, never bought —
					-- no price line on the preview card.
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
			warn("[StormChaserController] Missing " .. BillboardGuiTemplates.Path("SeedRoll") .. " BillboardGui")
		end

		local angle = 0
		local connection = RuntimeGuard.Connect(RunService.Heartbeat, "StormChaserController.SeedPreviewSpin", function(deltaTime)
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

	-- Rotates reward line -> forecast line -> experiment line -> next-tier
	-- tease, one per prompt. The dialogue stays hidden until prompted and
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
		lineIndex = lineIndex % 4 + 1
		clearSeedPreview()
		local text
		if lineIndex == 1 then
			local rewardSeedId = StormChaser.TierConfig(currentTier()).rewardSeedId
			local rewardName = Seeds.DisplayNameFor(rewardSeedId)
			local article = rewardName:match("^[AEIOUaeiou]") and "an" or "a"
			text = string.format("Fill the crates and receive %s %s!", article, rewardName)
			showSeedPreview(rewardSeedId)
		elseif lineIndex == 2 then
			local eventId = StormChaser.NextEvent(serverNow())
			text = StormChaser.ForecastLines[eventId] or ""
		elseif lineIndex == 3 then
			text = "Participate in my experiment and be rewarded!"
		else
			-- Tease the tier after the current one; NextTier loops the last
			-- tier back to 1, so the preview always has a reward to show.
			local nextRewardSeedId = StormChaser.TierConfig(StormChaser.NextTier(currentTier())).rewardSeedId
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

	local prompt = makePrompt(torso, "Ask the Scientist", "TreeGroundPickup")
	LocalPrompts.RegisterExternalPrompt(prompt, function()
		return PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true
	end)
	RuntimeGuard.Connect(prompt.Triggered, "StormChaserController.ScientistTriggered", speak)

	local timerGui = torso:WaitForChild("NextStorm", WAIT_SECONDS)
	local timerFrame = timerGui and timerGui:FindFirstChild("Frame")
	local timerLabel = timerFrame and timerFrame:FindFirstChild("Timer")
	if timerLabel and timerLabel:IsA("TextLabel") then
		task.spawn(function()
			while timerLabel.Parent do
				local now = serverNow()
				-- While the current slot's storm is still running (wind-up
				-- through wind-down), show NOW instead of the countdown.
				local currentEventId, slotStart = StormChaser.CurrentEvent(now)
				local currentEndsAt = slotStart + GameEvents.TotalDuration(GameEvents.GetEvent(currentEventId))
				if now < currentEndsAt then
					timerLabel.Text = "Next Natural Disaster: NOW"
				else
					local _, startsAt = StormChaser.NextEvent(now)
					timerLabel.Text = "Next Natural Disaster: " .. GameEvents.FormatDuration(startsAt - now)
				end
				task.wait(COUNTDOWN_STEP_SECONDS)
			end
		end)
	else
		warn("[StormChaserController] Missing NextStorm timer label")
	end
end

local function setupRadar(activeFolder)
	-- Either the bare MeshPart or its persistent-streaming Model wrapper.
	local dish = activeFolder:WaitForChild("RadarDish", WAIT_SECONDS)
	if not (dish and (dish:IsA("BasePart") or dish:IsA("Model"))) then
		warn("[StormChaserController] Missing RadarDish — skipping")
		return
	end
	local radiansPerSecond = math.pi * 2 / RADAR_REVOLUTION_SECONDS
	RuntimeGuard.Connect(RunService.Heartbeat, "StormChaserController.RadarSpin", function(deltaTime)
		dish:PivotTo(dish:GetPivot() * CFrame.Angles(0, radiansPerSecond * deltaTime, 0))
	end)
end

function StormChaserController.start()
	RuntimeGuard.Connect(resultRemote.OnClientEvent, "StormChaserController.Result", function(payload)
		if type(payload) ~= "table" or payload.requestId ~= pendingRequestId then
			return
		end
		pendingRequestId = nil
		if payload.success == true and payload.code == "deposited" then
			local record = crates[payload.mutationId]
			SoundEffects.PlayVaried(SoundEffects.Names.CrateDeposit, {
				parent = record and record.body or nil,
				range = 60,
			})
		end
	end)

	task.spawn(function()
		local map = Workspace:WaitForChild("Map", WAIT_SECONDS)
		local eventFolder = map and map:WaitForChild(StormChaser.MapFolderName, WAIT_SECONDS)
		local activeFolder = eventFolder and eventFolder:WaitForChild(StormChaser.ActiveFolderName, WAIT_SECONDS)
		if not activeFolder then
			warn("[StormChaserController] Missing Workspace.Map." .. StormChaser.MapFolderName .. "." .. StormChaser.ActiveFolderName .. " — skipping")
			return
		end

		for _, mutationId in ipairs(StormChaser.CrateMutationIds) do
			bindCrate(activeFolder, mutationId)
		end
		setupScientist(activeFolder)
		setupRadar(activeFolder)

		PlayerStateStore.Observe(PlayerStateStore.Fields.StormChaser, function()
			refreshCrates()
		end)
		refreshCrates()
	end)
end

return StormChaserController
