-- Drives the SocialMedia menu panel: players paste the 9-character code the
-- Discord bot gives them, the server validates its composition, and a
-- Watermelon seed is granted once per player. The panel is opened only from
-- its topbar icon; the reward patch spins in the panel viewport with the same
-- framing the Index uses for patches.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GrowingVisuals = require(Shared:WaitForChild("GrowingVisuals"))
local MediaReward = require(Shared:WaitForChild("MediaReward"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))

local FeedDisplayModel = require(script.Parent:WaitForChild("FeedDisplayModel"))
local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local Notifications = require(script.Parent:WaitForChild("Notifications"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))
local ViewportPreview = require(script.Parent:WaitForChild("ViewportPreview"))

local MediaRewardController = {}

local PANEL_NAME = MediaReward.PanelName
local MENU_GROUP = "media-reward"
local TOPBAR_ICON_NAME = "MediaReward"
local TOPBAR_ICON_IMAGE = "rbxassetid://135231056560398"
local RESULT_TIMEOUT_SECONDS = 10
-- Same patch framing as the Index info viewport (turntable spin, slight
-- top-down tilt so the flat patch reads instead of cropping to its center).
local PATCH_VIEWPORT_OPTIONS = { zoom = 2.1, cameraHeightFactor = 0.6 }
local COLLECTED_PLACEHOLDER = "Reward collected!"

local started = false

local function trim(value)
	return string.match(tostring(value or ""), "^%s*(.-)%s*$")
end

local function findDescendant(root, name, className)
	for _, descendant in ipairs(root and root:GetDescendants() or {}) do
		if descendant.Name == name and (not className or descendant:IsA(className)) then
			return descendant
		end
	end
	return nil
end

local function requireTopbarIcon()
	local satchelRoot = ReplicatedStorage:WaitForChild("Satchel", 10)
	if not satchelRoot then
		warn("[MediaRewardController] Missing ReplicatedStorage.Satchel; media reward toolbar icon will not start")
		return nil
	end

	local loader = satchelRoot:WaitForChild("SatchelLoader", 10)
	local satchelModule = loader and loader:WaitForChild("Satchel", 10)
	local packages = satchelModule and satchelModule:WaitForChild("Packages", 10)
	local topbarPlus = packages and packages:WaitForChild("topbarplus", 10)
	if not topbarPlus then
		warn("[MediaRewardController] Missing Satchel TopbarPlus module; media reward toolbar icon will not start")
		return nil
	end

	return require(topbarPlus)
end

-- Index-style preview: the reward seed's patch with its grown food pinned on
-- (FeedDisplayModel.Build), resolved through the seed -> machine link so the
-- model follows the configured reward.
local function rewardDisplayModel()
	local seedId = MediaReward.Reward.Id
	local feedType = Seeds.FeedTypeFor(seedId)
	local machine = feedType and GrowingVisuals.FeedTemplateFor(feedType)
	local model = machine and FeedDisplayModel.Build(machine)
	if model then
		return model
	end
	warn("[MediaRewardController] Missing patch display model for seed " .. tostring(seedId))
	return Seeds.GetTemplate(seedId)
end

function MediaRewardController.start()
	if started then
		return
	end
	started = true

	local panel = MenuGui.GetFrame(PANEL_NAME, "MediaRewardController")
	if not panel then
		return
	end

	local closeButton = findDescendant(panel, "CloseButton", "GuiButton")
	local verifyButton = findDescendant(panel, "VerifyButton", "GuiButton")
	local codeBox = findDescendant(panel, "TextBox", "TextBox")
	local viewport = findDescendant(panel, "Icon", "ViewportFrame")
	if not (closeButton and verifyButton and codeBox) then
		warn("[MediaRewardController] SocialMedia UI is missing CloseButton, VerifyButton, or TextBox")
		panel.Visible = false
		return
	end

	local requestRemote = Remotes.get(Remotes.Names.MediaRewardRedeemRequest)
	local resultRemote = Remotes.get(Remotes.Names.MediaRewardRedeemResult)

	UiEffects.BindAllButtons(panel)
	if viewport then
		ViewportPreview.Render(viewport, rewardDisplayModel(), PATCH_VIEWPORT_OPTIONS)
	end

	local panelState = UiEffects.PreparePanel(panel)
	local isOpen = false
	local transitionToken = 0
	local topbarIcon = nil
	local syncingIcon = false
	local collected = PlayerStateStore.Get(PlayerStateStore.Fields.MediaRewardCollected) == true
	local nextRequestId = 0
	local pendingRequestId = nil
	local basePlaceholder = codeBox.PlaceholderText

	local function updateInteractive()
		local interactive = not collected and pendingRequestId == nil
		UiEffects.SetButtonEnabled(verifyButton, interactive)
		codeBox.TextEditable = not collected
		if collected then
			codeBox.Text = ""
			codeBox.PlaceholderText = COLLECTED_PLACEHOLDER
		else
			codeBox.PlaceholderText = basePlaceholder
		end
	end

	local function removeTopbarIcon()
		local icon = topbarIcon
		if not icon then
			return
		end
		topbarIcon = nil
		pcall(function()
			icon:destroy()
		end)
	end

	local function syncTopbarIcon(selected)
		if not topbarIcon then
			return
		end
		syncingIcon = true
		if selected then
			topbarIcon:select()
		else
			topbarIcon:deselect()
		end
		syncingIcon = false
	end

	local function showPanel()
		if isOpen then
			return
		end
		isOpen = true
		transitionToken += 1
		UiEffects.PlayOpen(panel, panelState)
		syncTopbarIcon(true)
	end

	local function hidePanel(switching)
		if not isOpen and not panel.Visible then
			return
		end
		isOpen = false
		transitionToken += 1
		local token = transitionToken
		syncTopbarIcon(false)
		if switching then
			panel.Visible = false
			panel.Position = panelState.closedPosition
			panel.Size = panelState.closedSize
			return
		end
		UiEffects.PlayClose(panel, panelState, function()
			if transitionToken == token and not isOpen then
				panel.Visible = false
			end
		end)
	end

	local function submitCode()
		if collected or pendingRequestId ~= nil then
			return
		end
		if PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true then
			return
		end

		local code = trim(codeBox.Text)
		if not MediaReward.ValidateCode(code) then
			Notifications.show({
				text = MediaReward.InvalidCodeMessage,
				kind = NotificationConfig.Kinds.Error,
			})
			return
		end

		nextRequestId += 1
		pendingRequestId = nextRequestId
		updateInteractive()
		requestRemote:FireServer(pendingRequestId, code)

		-- If the result never arrives, unfreeze the button instead of leaving
		-- the panel dead.
		local requestId = pendingRequestId
		task.delay(RESULT_TIMEOUT_SECONDS, function()
			if pendingRequestId == requestId then
				pendingRequestId = nil
				updateInteractive()
			end
		end)
	end

	MenuGui.RegisterPanel(PANEL_NAME, {
		group = MENU_GROUP,
		open = showPanel,
		close = hidePanel,
	})

	RuntimeGuard.Connect(closeButton.Activated, "MediaRewardController.CloseActivated", function()
		MenuGui.ClosePanel(PANEL_NAME)
	end)
	RuntimeGuard.Connect(verifyButton.Activated, "MediaRewardController.VerifyActivated", submitCode)
	RuntimeGuard.Connect(codeBox.FocusLost, "MediaRewardController.CodeFocusLost", function(enterPressed)
		if enterPressed then
			submitCode()
		end
	end)

	RuntimeGuard.Connect(resultRemote.OnClientEvent, "MediaRewardController.RedeemResult", function(payload)
		if type(payload) ~= "table" or payload.requestId ~= pendingRequestId then
			return
		end
		pendingRequestId = nil
		if payload.success == true then
			codeBox.Text = ""
		end
		updateInteractive()
	end)

	PlayerStateStore.Observe(PlayerStateStore.Fields.MediaRewardCollected, function(value)
		collected = value == true
		updateInteractive()
		-- The icon only exists while the reward is still claimable.
		if collected then
			removeTopbarIcon()
		end
	end)
	updateInteractive()

	-- Topbar icon (right side): backpack (-1), index (0), edit (1), this (2);
	-- the settings icon owns 3 so this one stays second-to-last.
	RuntimeGuard.Spawn("MediaRewardController.TopbarIcon", function()
		-- Wait for the profile before deciding, so returning players who already
		-- collected never see the icon flash in and vanish.
		local waitedUntil = os.clock() + 15
		while PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true and os.clock() < waitedUntil do
			task.wait(0.2)
		end
		if collected then
			return
		end
		local Icon = requireTopbarIcon()
		if not Icon then
			return
		end
		local icon = Icon.new()
			:setName(TOPBAR_ICON_NAME)
			:setImage(TOPBAR_ICON_IMAGE)
			:setImageScale(0.7)
			:setCaption("Discord Reward")
			:setAlignment("Right")
			:setOrder(2)
			:autoDeselect(false)
		icon:modifyTheme({
			{ "IconButton", "BackgroundColor3", Color3.fromRGB(0, 0, 0) },
			{ "IconButton", "BackgroundTransparency", 0.2 },
			{ "IconCorners", "CornerRadius", UDim.new(1, 0) },
			{ "IconSpot", "BackgroundTransparency", 1, "Selected" },
			{ "IconSpotGradient", "Enabled", false, "Selected" },
		})
		RuntimeGuard.Connect(icon.toggled, "MediaRewardController.IconToggled", function(selected, fromSource)
			if syncingIcon or fromSource ~= "User" then
				return
			end
			if selected then
				MenuGui.OpenPanel(PANEL_NAME)
			else
				MenuGui.ClosePanel(PANEL_NAME)
			end
		end)
		topbarIcon = icon
		-- The flag may have flipped while the icon was being built.
		if collected then
			removeTopbarIcon()
			return
		end
		-- The panel may already be open/closed by the time the icon resolves.
		syncTopbarIcon(MenuGui.IsOpen(PANEL_NAME))
	end)
end

return MediaRewardController
