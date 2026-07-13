-- Physical starter pack offer on the player's own plot. When the active
-- starter pack (ShopBalance.StarterPackForRebirths) has been available for the
-- pack's PromptDelaySeconds — measured from tutorial completion for the
-- StarterPack, or from rebirth eligibility for the later packs — the
-- Assets.Misc.StarterPackPrompt model spins in on the plot's
-- Signs.PlotStarterPackPrompt pad with the StarterPackOffer billboard adorned
-- to its UIAttachment. E (ProximityPrompt) starts the normal purchase flow via
-- StarterPackController.RequestPurchase; the billboard CloseButton dismisses
-- the offer permanently for that pack (profile-persisted through
-- StarterPackPromptDismissRequest). Everything here is client-local
-- presentation; purchases and dismissals are validated server-side.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))

local BillboardGuiTemplates = require(script.Parent:WaitForChild("BillboardGuiTemplates"))
local LocalPrompts = require(script.Parent:WaitForChild("LocalPrompts"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local StarterPackController = require(script.Parent:WaitForChild("StarterPackController"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local StarterPackPromptController = {}

-- Each pack has its own Assets.Misc.<PackId>Prompt model; the base pack's
-- model doubles as the fallback if a pack-specific one goes missing.
local FALLBACK_MODEL_NAME = "StarterPackPrompt"
local SIGN_PART_NAME = "PlotStarterPackPrompt"
local BILLBOARD_TEMPLATE_NAME = "StarterPackOffer"
local OFFER_MAX_DISTANCE = 25
local PROMPT_DISTANCE = 7
local SHOW_SECONDS = 3
local SPIN_TURNS = 2 -- full 360s beyond the final player-facing yaw
local HIDE_SECONDS = 0.25
local BOB_HEIGHT_STUDS = 0.25 -- idle: peak vertical offset of the bob
local BOB_PERIOD_SECONDS = 2 -- idle: one full up-down cycle
local IDLE_TURN_SECONDS = 8 -- idle: one slow full rotation
-- Never park at zero: zero-size world guis permanently break glyph layout
-- (see UiEffects), and ScaleTo rejects zero.
local MIN_SCALE = 0.05
local EVAL_INTERVAL = 1

local player = Players.LocalPlayer
local dismissRemote = Remotes.get(Remotes.Names.StarterPackPromptDismissRequest)

local active = nil
local eligibleSincePackId = nil
local eligibleSince = 0
local dismissedLocally = {} -- optimistic CloseButton state until the replica catches up
local warned = {}

local function warnOnce(key, message)
	if not warned[key] then
		warned[key] = true
		warn("[StarterPackPromptController] " .. message)
	end
end

local function isDismissed(packId)
	if dismissedLocally[packId] == true then
		return true
	end
	local dismissed = PlayerStateStore.Get(PlayerStateStore.Fields.StarterPackPromptDismissed)
	return type(dismissed) == "table" and dismissed[packId] == true
end

local function isOwned(packId)
	local purchases = PlayerStateStore.Get(PlayerStateStore.Fields.StarterPackPurchases)
	if type(purchases) == "table" and purchases[packId] ~= nil then
		return purchases[packId] == true
	end
	return packId == "StarterPack" and PlayerStateStore.Get(PlayerStateStore.Fields.StarterPackPurchased) == true
end

-- Local-player tutorial state comes from the replica (the OnboardingActive
-- attribute is a cross-player mirror and lags dev-only tutorial skips).
local function isTutorialActive()
	local state = Onboarding.SanitizeState(
		PlayerStateStore.Get(PlayerStateStore.Fields.Onboarding),
		Onboarding.CompleteState()
	)
	return Onboarding.IsActive(state.Stage)
end

local function eligiblePack()
	if PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true then
		return nil
	end
	if isTutorialActive() then
		return nil
	end
	local rebirths = math.max(math.floor(tonumber(PlayerStateStore.Get(PlayerStateStore.Fields.Rebirths)) or 0), 0)
	local pack = ShopBalance.StarterPackForRebirths(rebirths)
	if not pack or isOwned(pack.PackId) or isDismissed(pack.PackId) then
		return nil
	end
	return pack
end

local function signPartCFrame()
	local plot = PlotResolver.ResolveForPlayer(player)
	local signs = plot and plot:FindFirstChild("Signs")
	local part = signs and signs:FindFirstChild(SIGN_PART_NAME)
	if part and part:IsA("BasePart") then
		return part.CFrame
	end
	return nil
end

-- Yaw whose LookVector points from `position` toward the local character.
local function facingYawTowardPlayer(position)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local camera = Workspace.CurrentCamera
	local target = root and root.Position or (camera and camera.CFrame.Position)
	if not target then
		return 0
	end
	local dx, dz = target.X - position.X, target.Z - position.Z
	if dx * dx + dz * dz < 0.001 then
		return 0
	end
	return math.atan2(-dx, -dz)
end

local function sortedTemplates(items)
	local slots = {}
	for _, item in ipairs(items and items:GetChildren() or {}) do
		if item.Name == "Template" and item:IsA("GuiObject") then
			slots[#slots + 1] = item
		end
	end
	table.sort(slots, function(left, right)
		return left.LayoutOrder < right.LayoutOrder
	end)
	return slots
end

local function hide()
	local record = active
	if not record or record.hiding then
		return
	end
	record.hiding = true
	active = nil

	for _, connection in ipairs(record.connections) do
		connection:Disconnect()
	end
	if record.unregister then
		record.unregister()
	end
	if record.prompt then
		record.prompt:Destroy()
	end
	if record.billboard then
		local billboard = record.billboard
		billboard.Enabled = false -- distance pop plays the shrink tween
		task.delay(1, function()
			billboard:Destroy()
		end)
	end
	if record.billboardAnchor then
		local anchor = record.billboardAnchor
		task.delay(1, function()
			anchor:Destroy()
		end)
	end

	local model = record.model
	RuntimeGuard.Spawn("StarterPackPromptController.HideTween", function()
		local startScale = model:GetScale()
		local startClock = os.clock()
		while model.Parent ~= nil do
			local alpha = (os.clock() - startClock) / HIDE_SECONDS
			if alpha >= 1 then
				break
			end
			model:ScaleTo(math.max(startScale * (1 - alpha), MIN_SCALE))
			task.wait()
		end
		model:Destroy()
	end)
end

local function dismiss(record)
	dismissedLocally[record.packId] = true
	dismissRemote:FireServer(record.packId)
	hide()
end

local function showBillboard(record)
	if record.hiding or record.billboard then
		return
	end
	local template = BillboardGuiTemplates.Find(BILLBOARD_TEMPLATE_NAME)
	if not (template and template:IsA("BillboardGui")) then
		warnOnce("billboard", "Missing " .. BillboardGuiTemplates.Path(BILLBOARD_TEMPLATE_NAME) .. " BillboardGui")
		return
	end
	local attachment = record.model:FindFirstChild("UIAttachment", true)
	if not (attachment and attachment:IsA("Attachment")) then
		warnOnce("attachment-" .. record.model.Name, "Assets.Misc." .. record.model.Name .. " is missing a UIAttachment Attachment")
		return
	end

	-- The model keeps bobbing/turning while idle; adorn the billboard to a
	-- stationary anchor frozen at the attachment's settled pose instead so the
	-- offer card holds still.
	local anchor = Instance.new("Part")
	anchor.Name = "__StarterPackOfferAnchor"
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.CFrame = CFrame.new(attachment.WorldPosition)
	anchor.Parent = Workspace
	record.billboardAnchor = anchor

	local billboard = template:Clone()
	billboard.Enabled = false
	local card = billboard:FindFirstChild("StarterPack")
	local title = card and card:FindFirstChild("Name")
	local timer = card and card:FindFirstChild("Timer")
	local closeButton = card and card:FindFirstChild("CloseButton")
	local items = card and card:FindFirstChild("Items")
	if not (card and items) then
		warnOnce("billboard-card", BillboardGuiTemplates.Path(BILLBOARD_TEMPLATE_NAME) .. " is missing the StarterPack.Items frame")
		billboard:Destroy()
		return
	end

	UiEffects.SetTextStack(title, record.pack.DisplayName or "Starter Pack")
	local rewards = StarterPackController.RewardsForPack(record.pack)
	for index, slot in ipairs(sortedTemplates(items)) do
		StarterPackController.RenderRewardSlot(slot, rewards[index])
	end
	record.timerLabel = timer
	if timer then
		UiEffects.SetTextStack(timer, StarterPackController.FormatCycleTimer())
	end
	local price = card:FindFirstChild("Price")
	if price and price:IsA("TextLabel") then
		local productId = tonumber(record.pack.DevProductId) or 0
		local function applyPrice()
			if price.Parent then
				UiEffects.SetTextStack(price, StarterPackController.RobuxPriceText(productId, nil))
			end
		end
		UiEffects.SetTextStack(price, StarterPackController.RobuxPriceText(productId, applyPrice))
	else
		warnOnce("billboard-price", BillboardGuiTemplates.Path(BILLBOARD_TEMPLATE_NAME) .. " is missing the StarterPack.Price TextLabel")
	end
	if closeButton and closeButton:IsA("GuiButton") then
		UiEffects.BindButton(closeButton)
		record.connections[#record.connections + 1] = RuntimeGuard.Connect(closeButton.Activated, "StarterPackPromptController.Close", function()
			dismiss(record)
		end)
	else
		warnOnce("billboard-close", BillboardGuiTemplates.Path(BILLBOARD_TEMPLATE_NAME) .. " is missing the StarterPack.CloseButton GuiButton")
	end

	billboard.MaxDistance = OFFER_MAX_DISTANCE
	-- GuiButtons inside a BillboardGui only receive input while the billboard
	-- is Active (the authored template ships Active=false).
	billboard.Active = true
	UiEffects.BindBillboardDistancePop(billboard)
	billboard.Adornee = anchor
	billboard.Parent = player:WaitForChild("PlayerGui")
	billboard.Enabled = true
	record.billboard = billboard
end

local function createPrompt(record)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "__LocalPrompt_StarterPackOffer"
	prompt.ActionText = "Buy"
	prompt.ObjectText = ""
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.Parent = record.model.PrimaryPart
	record.prompt = prompt
	record.unregister = LocalPrompts.RegisterExternalPrompt(prompt, function()
		return active == record and not record.hiding
	end)
	record.connections[#record.connections + 1] = RuntimeGuard.Connect(prompt.Triggered, "StarterPackPromptController.Buy", function()
		StarterPackController.RequestPurchase(record.packId)
	end)
end

-- Spin-in: two fast full turns decelerating (quad out) into the player-facing
-- yaw over SHOW_SECONDS, scaling up from MIN_SCALE alongside. Afterwards the
-- model idles in place: a gentle sine bob plus a slow continuous turn, both
-- continuing from where the spin-in settled so the handoff is seamless. The
-- connection lives until hide() disconnects it.
local function playShowAnimation(record, position)
	local model = record.model
	local finalYaw = facingYawTowardPlayer(position)
	local spinTotal = SPIN_TURNS * math.pi * 2
	local startClock = os.clock()

	model:ScaleTo(MIN_SCALE)
	model:PivotTo(CFrame.new(position) * CFrame.Angles(0, finalYaw - spinTotal, 0))

	local billboardShown = false
	record.connections[#record.connections + 1] = RuntimeGuard.Connect(RunService.Heartbeat, "StarterPackPromptController.Animate", function()
		if record.hiding or model.Parent == nil then
			return
		end
		local elapsed = os.clock() - startClock
		if elapsed < SHOW_SECONDS then
			local eased = TweenService:GetValue(elapsed / SHOW_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			model:ScaleTo(math.max(eased, MIN_SCALE))
			model:PivotTo(CFrame.new(position) * CFrame.Angles(0, finalYaw - spinTotal * (1 - eased), 0))
			return
		end
		if not billboardShown then
			billboardShown = true
			model:ScaleTo(1)
			showBillboard(record)
			-- Created only after the final ScaleTo: Model:ScaleTo rescales
			-- descendant ProximityPrompt.MaxActivationDistance, so a prompt
			-- present during the scale-in ends up at range / MIN_SCALE
			-- (observed: 15 -> 300 studs).
			createPrompt(record)
		end
		local idle = elapsed - SHOW_SECONDS
		local bob = math.sin(idle * math.pi * 2 / BOB_PERIOD_SECONDS) * BOB_HEIGHT_STUDS
		local yaw = finalYaw + idle * math.pi * 2 / IDLE_TURN_SECONDS
		model:PivotTo(CFrame.new(position + Vector3.new(0, bob, 0)) * CFrame.Angles(0, yaw, 0))
	end)
end

local function show(pack)
	local signCFrame = signPartCFrame()
	if not signCFrame then
		-- Plot or sign pad not resolved/streamed yet; the heartbeat retries.
		return
	end
	local misc = Assets.Find(Assets.Names.Misc)
	local modelName = tostring(pack.PackId) .. "Prompt"
	local template = misc and misc:FindFirstChild(modelName)
	if not (template and template:IsA("Model") and template.PrimaryPart) then
		warnOnce("model-" .. modelName, "Missing ReplicatedStorage.Assets.Misc." .. modelName .. " Model with a PrimaryPart; falling back to " .. FALLBACK_MODEL_NAME)
		template = misc and misc:FindFirstChild(FALLBACK_MODEL_NAME)
	end
	if not (template and template:IsA("Model") and template.PrimaryPart) then
		warnOnce("model-fallback", "Missing ReplicatedStorage.Assets.Misc." .. FALLBACK_MODEL_NAME .. " Model with a PrimaryPart")
		return
	end

	local model = template:Clone()
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
		end
	end

	local record = {
		packId = pack.PackId,
		pack = pack,
		model = model,
		connections = {},
	}
	active = record
	local position = signCFrame.Position + Vector3.new(0, model:GetExtentsSize().Y / 2, 0)
	model:PivotTo(CFrame.new(position))
	model.Parent = Workspace
	playShowAnimation(record, position)
end

local function evaluate()
	local pack = eligiblePack()
	local packId = pack and pack.PackId or nil

	if active and active.packId ~= packId then
		hide()
	end
	if packId ~= eligibleSincePackId then
		eligibleSincePackId = packId
		eligibleSince = os.clock()
	end
	if pack and not active then
		local delaySeconds = math.max(tonumber(pack.PromptDelaySeconds) or 0, 0)
		if os.clock() - eligibleSince >= delaySeconds then
			show(pack)
		end
	end
	if active and active.timerLabel then
		UiEffects.SetTextStack(active.timerLabel, StarterPackController.FormatCycleTimer())
	end
end

function StarterPackPromptController.start()
	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, evaluate)
	PlayerStateStore.Observe(PlayerStateStore.Fields.Rebirths, evaluate)
	PlayerStateStore.Observe(PlayerStateStore.Fields.StarterPackPurchased, evaluate)
	PlayerStateStore.Observe(PlayerStateStore.Fields.StarterPackPurchases, evaluate)
	PlayerStateStore.Observe(PlayerStateStore.Fields.StarterPackPromptDismissed, evaluate)
	PlayerStateStore.Observe(PlayerStateStore.Fields.Onboarding, evaluate)

	local elapsed = 0
	RuntimeGuard.Connect(RunService.Heartbeat, "StarterPackPromptController.Tick", function(dt)
		elapsed += dt
		if elapsed < EVAL_INTERVAL then
			return
		end
		elapsed = 0
		evaluate()
	end)
end

return StarterPackPromptController
