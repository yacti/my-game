-- Renders the player's HUD from the Studio-authored template at
-- ReplicatedStorage.UI.HUD.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService     = game:GetService("SocialService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local ResponsiveHud = require(script.Parent:WaitForChild("ResponsiveHud"))
local ResponsiveUi = require(script.Parent:WaitForChild("ResponsiveUi"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local HudController = {}
local LEFT_BUTTONS_NAME = "LeftButtons"
local TOP_BAR_NAME = "TopBar"
local HOME_BUTTON_NAME = "Home"
local HIDDEN_ON_CLONE = {
	SkipTimeButtons = true,
}
local HOME_TELEPORT_COOLDOWN_SECONDS = 0.75

local HomeTeleportRequest = Remotes.get(Remotes.Names.HomeTeleportRequest)

local function findCurrencyLabel(gui)
	local currency = gui:FindFirstChild("Currency")
	if not (currency and currency:IsA("GuiObject")) then
		warn("[HudController] HUD missing Currency GuiObject")
		return nil
	end

	local label = currency:FindFirstChild("CurrencyLabel")
	if label and label:IsA("TextLabel") then return label end
	warn("[HudController] HUD missing Currency.CurrencyLabel TextLabel")
	return nil
end

local function findFriendBoostLabel(gui)
	local currency = gui:FindFirstChild("Currency")
	if not (currency and currency:IsA("GuiObject")) then
		return nil
	end

	local label = currency:FindFirstChild("FriendBoost")
	if label and label:IsA("TextLabel") then return label end
	warn("[HudController] HUD missing Currency.FriendBoost TextLabel")
	return nil
end

local function findInviteFriendsButton(gui)
	local currency = gui:FindFirstChild("Currency")
	if not (currency and currency:IsA("GuiObject")) then
		return nil
	end

	local button = currency:FindFirstChild("InviteFriends")
	if button and button:IsA("GuiButton") then return button end
	warn("[HudController] HUD missing Currency.InviteFriends GuiButton")
	return nil
end

local function cloneTemplate()
	local uiFolder = ReplicatedStorage:FindFirstChild("UI")
	local template = uiFolder and uiFolder:FindFirstChild("HUD")
	if template and template:IsA("ScreenGui") then return template:Clone() end
	warn("[HudController] Missing ReplicatedStorage.UI.HUD ScreenGui")
	return nil
end

local function hideInitialRuntimePanels(gui)
	for name in pairs(HIDDEN_ON_CLONE) do
		local object = gui:FindFirstChild(name)
		if object and object:IsA("GuiObject") then
			object.Visible = false
		end
	end
end

local function hiddenDuringTutorialObjects(gui)
	local objects = {}
	for _, name in ipairs(Onboarding.HiddenDuringActiveTutorial().Hud) do
		local object = gui:FindFirstChild(name, true)
		if object and object:IsA("GuiObject") then
			objects[#objects + 1] = object
		else
			warn("[HudController] HUD missing " .. tostring(name) .. " GuiObject")
		end
	end
	return objects
end

local function resolveButtonFromHomeNode(homeNode)
	if not homeNode then
		return nil
	end
	if homeNode:IsA("GuiButton") then
		return homeNode
	end
	for _, descendant in ipairs(homeNode:GetDescendants()) do
		if descendant:IsA("GuiButton") then
			return descendant
		end
	end
	return nil
end

local function bindHomeButton(topBar)
	if not (topBar and topBar:IsA("GuiObject")) then
		return
	end

	local homeNode = topBar:FindFirstChild(HOME_BUTTON_NAME, true)
	local button = resolveButtonFromHomeNode(homeNode)
	if not button then
		warn("[HudController] HUD.TopBar missing Home GuiButton or nested GuiButton")
		return
	end

	button.Active = true
	button.Selectable = true
	UiEffects.BindButton(button)
	local lastRequestAt = 0
	RuntimeGuard.Connect(button.Activated, "HudController.HomeActivated", function()
		local now = os.clock()
		if now - lastRequestAt < HOME_TELEPORT_COOLDOWN_SECONDS then
			return
		end
		lastRequestAt = now
		HomeTeleportRequest:FireServer()
	end)
end

local function bindInviteFriendsButton(button, player)
	if not button then
		return
	end

	button.Active = true
	button.Selectable = true
	UiEffects.BindButton(button)

	local promptInFlight = false
	RuntimeGuard.Connect(button.Activated, "HudController.InviteFriendsActivated", function()
		if promptInFlight then
			return
		end
		promptInFlight = true

		RuntimeGuard.Spawn("HudController.InviteFriendsPrompt", function()
			local canInvite = false
			local ok, result = pcall(function()
				return SocialService:CanSendGameInviteAsync(player)
			end)
			if ok then
				canInvite = result == true
			else
				warn("[HudController] CanSendGameInviteAsync failed: " .. tostring(result))
			end

			if canInvite then
				local promptOk, promptErr = pcall(function()
					SocialService:PromptGameInvite(player)
				end)
				if not promptOk then
					warn("[HudController] PromptGameInvite failed: " .. tostring(promptErr))
				end
			end

			promptInFlight = false
		end)
	end)
end

function HudController.start()
	local player    = Players.LocalPlayer
	local PlayerGui = player:WaitForChild("PlayerGui")

	local gui = cloneTemplate()
	if not gui then return end
	hideInitialRuntimePanels(gui)
	gui.Parent = PlayerGui
	ResponsiveUi.BindRoot(gui)
	ResponsiveHud.Bind(gui)

	local leftButtons = gui:FindFirstChild(LEFT_BUTTONS_NAME)
	if leftButtons and leftButtons:IsA("GuiObject") then
		UiEffects.BindAllButtons(leftButtons)
	else
		warn("[HudController] HUD missing LeftButtons GuiObject")
	end

	local label = findCurrencyLabel(gui)
	local friendBoostLabel = findFriendBoostLabel(gui)
	bindInviteFriendsButton(findInviteFriendsButton(gui), player)
	local hiddenDuringTutorial = hiddenDuringTutorialObjects(gui)
	local topBar = gui:FindFirstChild(TOP_BAR_NAME)
	if topBar and topBar:IsA("GuiObject") then
		topBar.Visible = false
		bindHomeButton(topBar)
	end

	local function setAmount(n)
		if label then label.Text = UiEffects.FormatCurrency(n) end
	end

	local function setFriendBoost(percent)
		percent = math.max(math.floor(tonumber(percent) or 0), 0)
		if friendBoostLabel then
			friendBoostLabel.Text = "Friend boost: +" .. tostring(percent) .. "%"
		end
	end

	local function setTutorialVisibility(state)
		local hasState = type(state) == "table"
		state = Onboarding.SanitizeState(state, Onboarding.CompleteState())
		local visible = not Onboarding.IsActive(state.Stage)
		for _, object in ipairs(hiddenDuringTutorial) do
			object.Visible = (object == topBar and not hasState) and false or visible
		end
	end

	setAmount(PlayerStateStore.Get(PlayerStateStore.Fields.Currency) or 0)
	PlayerStateStore.Observe(PlayerStateStore.Fields.Currency, setAmount)
	setFriendBoost(PlayerStateStore.Get(PlayerStateStore.Fields.FriendBoostPercent) or 0)
	PlayerStateStore.Observe(PlayerStateStore.Fields.FriendBoostPercent, setFriendBoost)
	setTutorialVisibility(PlayerStateStore.Get(PlayerStateStore.Fields.Onboarding))
	PlayerStateStore.Observe(PlayerStateStore.Fields.Onboarding, setTutorialVisibility)
end

return HudController
