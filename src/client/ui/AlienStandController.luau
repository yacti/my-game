-- Mr Alien's stand client (Workspace.Map.MrAlienEvent). Everything here is
-- per-player and cosmetic: the stand's arrival plays as a UFO descent followed
-- by everything else fading up beneath it, the AlienCrate's Fill part and
-- AlienFoodAmount billboard track the local player's replicated deposit
-- progress (profile.Data.AlienStand via PlayerStateStore), the crate prompt
-- fires AlienDepositRequest, Mr Alien rotates typewriter dialogue lines with
-- floating seed previews, and the HUD EventButton swaps to its AlienIcon while
-- the stand is up (the server points the EVENT teleport at AlienTeleport to
-- match).
--
-- The stand is a server-side clone that appears and disappears with the admin
-- toggle, so this controller binds off Workspace.Map ChildAdded/ChildRemoved
-- rather than at boot. The entrance is derived entirely from the folder's
-- AlienStandActivatedAt attribute, so a player who joins after it has played
-- simply sees the settled stand.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AlienStand = require(Shared:WaitForChild("AlienStand"))
local Food = require(Shared:WaitForChild("Food"))
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

local AlienStandController = {}

local WAIT_SECONDS = 15
local PROMPT_DISTANCE = 10
local PROMPT_ATTACHMENT_NAME = "__LocalPrompt_AlienStandAttachment"
local FILL_TWEEN_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TYPE_SECONDS_PER_GRAPHEME = 0.04
local MAX_TYPE_SECONDS = 3
local RESULT_TIMEOUT_SECONDS = 5
local DIALOGUE_TIMEOUT_SECONDS = 10
local DIALOGUE_LINE_COUNT = 3
local SEED_PREVIEW_RIGHT_STUDS = 3
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
local HUD_NAME = "HUD"
local LEFT_BUTTONS_NAME = "LeftButtons"
local EVENT_BUTTON_NAME = "EventButton"
local EVENT_ICON_NAME = "Icon"
local EVENT_ALIEN_ICON_NAME = "AlienIcon"

local player = Players.LocalPlayer
local requestRemote = Remotes.get(Remotes.Names.AlienDepositRequest)
local resultRemote = Remotes.get(Remotes.Names.AlienDepositResult)

local standFolder = nil
local bindToken = 0
local entranceSettled = false
local crateRecord = nil -- { body, fill, maxSize, bottomY, amountLabel, billboard, prompt, initialized }
local nextRequestId = 0
local pendingRequestId = nil
local cleanups = {}
local hudIconToken = 0

local function serverNow()
	return Workspace:GetServerTimeNow()
end

local function addCleanup(callback)
	if type(callback) == "function" then
		cleanups[#cleanups + 1] = callback
	end
end

local function standState()
	return PlayerStateStore.Get(PlayerStateStore.Fields.AlienStand)
end

local function currentTier()
	local state = standState()
	return AlienStand.NormalizeTier(state and state.Tier)
end

local function depositCount()
	local state = standState()
	local count = state and tonumber(state.Deposits) or 0
	return math.max(math.floor(count or 0), 0)
end

local function requiredDeposits()
	return AlienStand.RequiredFor(currentTier()) or 0
end

local function crateFilled()
	return depositCount() >= requiredDeposits()
end

local function hasAlienFoodEquipped()
	local character = player.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	if not tool or tool:GetAttribute(State.Food.Id) == nil then
		return false
	end
	return Mutations.Contains(Food.MutationIdsOf(tool), AlienStand.MutationId)
end

---------------------------------------------------------------------------
-- HUD EventButton icon
---------------------------------------------------------------------------

-- The stand can be raised before HudController has cloned the HUD, so the
-- swap waits for it on its own thread. The token drops a pending swap if the
-- stand comes down first.
local function setHudAlienIcon(active)
	hudIconToken += 1
	local token = hudIconToken
	task.spawn(function()
		local playerGui = player:WaitForChild("PlayerGui", WAIT_SECONDS)
		local hud = playerGui and playerGui:WaitForChild(HUD_NAME, WAIT_SECONDS)
		local leftButtons = hud and hud:WaitForChild(LEFT_BUTTONS_NAME, WAIT_SECONDS)
		local eventButton = leftButtons and leftButtons:WaitForChild(EVENT_BUTTON_NAME, WAIT_SECONDS)
		if not eventButton or hudIconToken ~= token then
			return
		end
		local icon = eventButton:FindFirstChild(EVENT_ICON_NAME)
		local alienIcon = eventButton:FindFirstChild(EVENT_ALIEN_ICON_NAME)
		if not (icon and icon:IsA("GuiObject") and alienIcon and alienIcon:IsA("GuiObject")) then
			warn("[AlienStandController] HUD.LeftButtons.EventButton missing Icon/" .. EVENT_ALIEN_ICON_NAME)
			return
		end
		icon.Visible = not active
		alienIcon.Visible = active
	end)
end

---------------------------------------------------------------------------
-- Entrance
---------------------------------------------------------------------------

-- Authored appearance captured before anything is hidden, so the entrance
-- always resolves to exactly what Studio authored rather than to hardcoded
-- zeroes. Instances already fully transparent (the Head, the Glow mesh, the
-- crate Fill) keep their authored values and are skipped.
local function collectFadeTargets(root, skip)
	local targets = { parts = {}, decals = {}, lights = {}, highlights = {} }
	local function consider(instance)
		if skip[instance] then
			return
		end
		for ancestor in pairs(skip) do
			if instance:IsDescendantOf(ancestor) then
				return
			end
		end
		if instance:IsA("BasePart") then
			if instance.Transparency < 1 then
				targets.parts[#targets.parts + 1] = { instance = instance, transparency = instance.Transparency }
			end
		elseif instance:IsA("Decal") or instance:IsA("Texture") then
			if instance.Transparency < 1 then
				targets.decals[#targets.decals + 1] = { instance = instance, transparency = instance.Transparency }
			end
		elseif instance:IsA("Light") then
			targets.lights[#targets.lights + 1] = { instance = instance, brightness = instance.Brightness }
		elseif instance:IsA("Highlight") then
			targets.highlights[#targets.highlights + 1] = {
				instance = instance,
				fill = instance.FillTransparency,
				outline = instance.OutlineTransparency,
			}
		end
	end
	consider(root)
	for _, descendant in ipairs(root:GetDescendants()) do
		consider(descendant)
	end
	return targets
end

local function applyFadeAlpha(targets, alpha)
	alpha = math.clamp(alpha, 0, 1)
	for _, entry in ipairs(targets.parts) do
		if entry.instance.Parent then
			entry.instance.Transparency = 1 - (1 - entry.transparency) * alpha
		end
	end
	for _, entry in ipairs(targets.decals) do
		if entry.instance.Parent then
			entry.instance.Transparency = 1 - (1 - entry.transparency) * alpha
		end
	end
	for _, entry in ipairs(targets.lights) do
		if entry.instance.Parent then
			entry.instance.Brightness = entry.brightness * alpha
		end
	end
	for _, entry in ipairs(targets.highlights) do
		if entry.instance.Parent then
			entry.instance.FillTransparency = 1 - (1 - entry.fill) * alpha
			entry.instance.OutlineTransparency = 1 - (1 - entry.outline) * alpha
		end
	end
end

-- Quad InOut, matching the eased hops the bee flight sim uses.
local function easedAlpha(alpha)
	alpha = math.clamp(alpha, 0, 1)
	if alpha < 0.5 then
		return 2 * alpha * alpha
	end
	return 1 - 2 * (1 - alpha) * (1 - alpha)
end

-- Drives the whole arrival off the server-stamped ActivatedAt: the UFO drops
-- from ufoDescendStuds up, then everything under it fades in. `onSettled`
-- runs once the stand is fully present (immediately for a late joiner).
local function playEntrance(folder, token, onSettled)
	local settings = AlienStand.Entrance
	local activatedAt = tonumber(folder:GetAttribute(State.AlienStand.ActivatedAt))
	local ufo = folder:FindFirstChild(AlienStand.UfoName)
	local finish = function()
		if bindToken == token then
			onSettled()
		end
	end

	if not activatedAt then
		warn("[AlienStandController] Stand has no " .. State.AlienStand.ActivatedAt .. "; skipping the entrance")
		finish()
		return
	end
	if serverNow() - activatedAt >= AlienStand.EntranceTotalSeconds() then
		finish()
		return
	end

	local skip = {}
	if ufo then
		skip[ufo] = true
	end
	local targets = collectFadeTargets(folder, skip)
	applyFadeAlpha(targets, 0)

	local ufoRestCFrame = ufo and ufo:GetPivot() or nil
	if ufo and ufoRestCFrame then
		ufo:PivotTo(ufoRestCFrame + Vector3.new(0, settings.ufoDescendStuds, 0))
	end

	local connection
	connection = RuntimeGuard.Connect(RunService.Heartbeat, "AlienStandController.Entrance", function()
		if bindToken ~= token or not folder.Parent then
			connection:Disconnect()
			return
		end
		local elapsed = serverNow() - activatedAt
		if ufo and ufoRestCFrame then
			local descendAlpha = easedAlpha(elapsed / settings.ufoDescendSeconds)
			ufo:PivotTo(ufoRestCFrame + Vector3.new(0, settings.ufoDescendStuds * (1 - descendAlpha), 0))
		end
		applyFadeAlpha(targets, (elapsed - settings.ufoDescendSeconds) / settings.fadeInSeconds)
		if elapsed >= AlienStand.EntranceTotalSeconds() then
			connection:Disconnect()
			if ufo and ufoRestCFrame then
				ufo:PivotTo(ufoRestCFrame)
			end
			applyFadeAlpha(targets, 1)
			finish()
		end
	end)
	addCleanup(function()
		connection:Disconnect()
	end)
end

---------------------------------------------------------------------------
-- Crate
---------------------------------------------------------------------------

-- The crate's Fill mesh is authored at its full size; the bottom face stays
-- put while the height scales with deposit progress (same as the Bee jar).
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

local function refreshCrate()
	local record = crateRecord
	-- Held back until the entrance settles so the fill does not pop in ahead
	-- of the crate it lives inside.
	if not (record and entranceSettled) then
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

local function crateAvailability(prompt)
	-- Nothing is interactable until the stand has finished landing; the crate
	-- is still transparent up to that point.
	if not entranceSettled then
		return false
	end
	if PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true or standState() == nil then
		return false
	end
	if pendingRequestId ~= nil then
		return false
	end
	-- A full crate means a reward grant was blocked (inventory full); the
	-- prompt retries the grant server-side.
	if crateFilled() then
		prompt.ActionText = "Collect Alien Reward"
		return true
	end
	if not hasAlienFoodEquipped() then
		return false
	end
	prompt.ActionText = "Deposit Alien Food"
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
	prompt.Name = "__LocalPrompt_AlienStand"
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

local function bindCrate(folder)
	local crate = folder:WaitForChild(AlienStand.CrateName, WAIT_SECONDS)
	local body = crate and crate:WaitForChild(AlienStand.CrateBodyName, WAIT_SECONDS)
	local fill = crate and crate:WaitForChild(AlienStand.CrateFillName, WAIT_SECONDS)
	if not (body and body:IsA("BasePart") and fill and fill:IsA("BasePart")) then
		warn("[AlienStandController] Missing " .. AlienStand.CrateName .. " parts — skipping")
		return
	end

	local billboard = body:FindFirstChild(AlienStand.CrateBillboardName, true)
	local amountLabel = billboard and billboard:FindFirstChild("Amount", true)
	if not (amountLabel and amountLabel:IsA("TextLabel")) then
		warn("[AlienStandController] Missing " .. AlienStand.CrateBillboardName .. " Amount label")
		amountLabel = nil
	end

	crateRecord = {
		body = body,
		fill = fill,
		maxSize = fill.Size,
		bottomY = fill.Position.Y - fill.Size.Y / 2,
		amountLabel = amountLabel,
		billboard = billboard,
		initialized = false,
	}
	-- Hidden for the entrance; refreshCrate restores both once it settles.
	fill.Transparency = 1
	if billboard and billboard:IsA("BillboardGui") then
		billboard.Enabled = false
	end

	local prompt = makePrompt(body, "Deposit Alien Food", "TreeGroundPickup")
	crateRecord.prompt = prompt
	addCleanup(LocalPrompts.RegisterExternalPrompt(prompt, function()
		return crateAvailability(prompt)
	end))
	RuntimeGuard.Connect(prompt.Triggered, "AlienStandController.CrateTriggered", function()
		if crateAvailability(prompt) then
			sendDeposit()
		end
	end)
end

---------------------------------------------------------------------------
-- Mr Alien dialogue
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
		warn("[AlienStandController] Failed to load animation " .. animationId)
		return nil
	end
	return track
end

local function bindNpc(folder)
	local rig = folder:WaitForChild(AlienStand.NpcName, WAIT_SECONDS)
	local humanoid = rig and rig:WaitForChild("Humanoid", WAIT_SECONDS)
	local torso = rig and rig:WaitForChild("Torso", WAIT_SECONDS)
	if not (humanoid and torso) then
		warn("[AlienStandController] Missing " .. AlienStand.NpcName .. " rig — skipping")
		return
	end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	local dialogueGui = torso:WaitForChild(AlienStand.NpcDialogueGuiName, WAIT_SECONDS)
	local dialogueFrame = dialogueGui and dialogueGui:FindFirstChild("Frame")
	local dialogueLabel = dialogueFrame and dialogueFrame:FindFirstChild("Dialogue")
	if not (dialogueLabel and dialogueLabel:IsA("TextLabel")) then
		warn("[AlienStandController] Missing " .. AlienStand.NpcDialogueGuiName .. " label")
		dialogueLabel = nil
	end
	if dialogueGui then
		dialogueGui.Enabled = false
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
		addCleanup(function()
			idleTrack:Stop()
		end)
	end
	local thinkingTrack = loadTrack(animator, rig:GetAttribute(THINKING_ANIMATION_ATTR))
	if thinkingTrack then
		thinkingTrack.Priority = Enum.AnimationPriority.Action
	end

	-- Same procedural gesture as the Beekeeper: with no R6 "thinking" animation
	-- available, the turn/tilt drives the Torso's Neck Motor6D C0 in torso
	-- space. A ThinkingAnimationId attribute replaces it with no code change.
	local neck = torso:FindFirstChild("Neck")
	if not (neck and neck:IsA("Motor6D")) then
		neck = nil
		warn("[AlienStandController] " .. AlienStand.NpcName .. " Torso has no Neck Motor6D; thinking tilt skipped")
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

		-- Face the local player, but never beyond TILT_MAX_TURN_RADIANS — a
		-- player standing behind him gets a partial turn, not a head spin.
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

	-- Floating reward-seed preview shown alongside the reward dialogue lines:
	-- the seed template spinning in front of Mr Alien with the SeedRoll
	-- billboard card from the crate-roll reveal.
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
	addCleanup(clearSeedPreview)

	local function showSeedPreview(rewardSeedId)
		clearSeedPreview()
		local template = Seeds.GetTemplate(rewardSeedId)
		if not template then
			warn("[AlienStandController] Missing seed template " .. tostring(rewardSeedId))
			return
		end
		local clone = template:Clone()
		clone.Name = "AlienStandSeedPreview"
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
		local base = torso.CFrame * CFrame.new(SEED_PREVIEW_RIGHT_STUDS, SEED_PREVIEW_HEIGHT_STUDS, 0)
		clone:PivotTo(base)
		clone.Parent = Workspace

		local animatedRarityLabel = nil
		local animatedRarity = nil
		local billboardTemplate = BillboardGuiTemplates.Find("SeedRoll")
		if billboardTemplate and billboardTemplate:IsA("BillboardGui") then
			local billboard = billboardTemplate:Clone()
			billboard.Name = "AlienStandSeedPreviewBillboard"
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
					-- Stand rewards are granted directly, never bought.
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
			warn("[AlienStandController] Missing " .. BillboardGuiTemplates.Path("SeedRoll") .. " BillboardGui")
		end

		local angle = 0
		local connection = RuntimeGuard.Connect(RunService.Heartbeat, "AlienStandController.SeedPreviewSpin", function(deltaTime)
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
	-- (the same three-line rotation as the Beekeeper). The dialogue stays
	-- hidden until prompted and hides again, with the seed preview,
	-- DIALOGUE_TIMEOUT_SECONDS after the last prompt.
	local dialogueToken = 0
	local lineIndex = 0
	local function hideDialogue()
		if dialogueGui then
			dialogueGui.Enabled = false
		end
		clearSeedPreview()
	end
	addCleanup(hideDialogue)

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
			local rewardSeedId = AlienStand.TierConfig(currentTier()).rewardSeedId
			local rewardName = Seeds.DisplayNameFor(rewardSeedId)
			local article = rewardName:match("^[AEIOUaeiou]") and "an" or "a"
			text = string.format("Fill the crate with Alien food and receive %s %s!", article, rewardName)
			showSeedPreview(rewardSeedId)
		elseif lineIndex == 2 then
			text = "My ship runs on Alien-mutated crops. Nothing else will do!"
		else
			-- Tease the tier after the current one; NextTier loops the last
			-- tier back to 1, so the preview always has a reward to show.
			local nextRewardSeedId = AlienStand.TierConfig(AlienStand.NextTier(currentTier())).rewardSeedId
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

	local prompt = makePrompt(torso, "Ask Mr Alien", "TreeGroundPickup")
	addCleanup(LocalPrompts.RegisterExternalPrompt(prompt, function()
		return entranceSettled and PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true
	end))
	RuntimeGuard.Connect(prompt.Triggered, "AlienStandController.NpcTriggered", speak)
end

---------------------------------------------------------------------------
-- Bind / unbind
---------------------------------------------------------------------------

-- Bumping the token invalidates every in-flight bind step and entrance loop,
-- so a stand that is lowered mid-arrival stops cleanly.
local function unbindStand()
	bindToken += 1
	entranceSettled = false
	for index = #cleanups, 1, -1 do
		local cleanup = cleanups[index]
		cleanups[index] = nil
		RuntimeGuard.Run("AlienStandController.Cleanup", cleanup)
	end
	crateRecord = nil
	pendingRequestId = nil
	standFolder = nil
	setHudAlienIcon(false)
end

local function bindStand(folder)
	if standFolder == folder then
		return
	end
	unbindStand()
	standFolder = folder
	local token = bindToken

	setHudAlienIcon(true)

	task.spawn(function()
		bindCrate(folder)
		if bindToken ~= token then
			return
		end
		bindNpc(folder)
		if bindToken ~= token then
			return
		end
		playEntrance(folder, token, function()
			entranceSettled = true
			local record = crateRecord
			if record and record.billboard and record.billboard:IsA("BillboardGui") then
				record.billboard.Enabled = true
			end
			refreshCrate()
		end)
	end)
end

function AlienStandController.start()
	if not AlienStand.Enabled then
		return
	end

	RuntimeGuard.Connect(resultRemote.OnClientEvent, "AlienStandController.Result", function(payload)
		if type(payload) ~= "table" or payload.requestId ~= pendingRequestId then
			return
		end
		pendingRequestId = nil
		if payload.success == true and payload.code == "deposited" then
			SoundEffects.PlayVaried(SoundEffects.Names.CrateDeposit, {
				parent = crateRecord and crateRecord.body or nil,
				range = 60,
			})
		end
	end)

	task.spawn(function()
		local map = Workspace:WaitForChild(AlienStand.MapFolderName, WAIT_SECONDS)
		if not map then
			warn("[AlienStandController] Missing Workspace." .. AlienStand.MapFolderName .. " — skipping")
			return
		end

		-- The stand is cloned in and destroyed by the server toggle, so the
		-- folder can arrive at any time (including before this runs).
		local existing = map:FindFirstChild(AlienStand.TemplateName)
		if existing then
			bindStand(existing)
		end
		RuntimeGuard.Connect(map.ChildAdded, "AlienStandController.StandAdded", function(child)
			if child.Name == AlienStand.TemplateName then
				bindStand(child)
			end
		end)
		RuntimeGuard.Connect(map.ChildRemoved, "AlienStandController.StandRemoved", function(child)
			if child == standFolder then
				unbindStand()
			end
		end)
	end)

	PlayerStateStore.Observe(PlayerStateStore.Fields.AlienStand, function()
		refreshCrate()
	end)
end

return AlienStandController
