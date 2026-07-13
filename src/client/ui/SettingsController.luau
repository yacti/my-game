-- Wires the Studio-authored Menu.Settings panel: profile-backed on/off rows
-- (music, tree fruit auto-collect, accept gifts) rendered from the replicated
-- PlayerSettings field, plus a right-aligned TopbarPlus icon that toggles the
-- panel. Each row has two overlapping On/Off ImageButtons; the one matching
-- the current state is visible and clicking either flips the setting.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local PlayerSettings = require(Shared:WaitForChild("PlayerSettings"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local SettingsController = {}

local PANEL_NAME = "Settings"
local ROW_NAME_PREFIX = "PlayerSetting_"
local TOPBAR_SETTINGS_ICON_NAME = "SettingsMenu"
local TOPBAR_SETTINGS_ICON_IMAGE = "rbxassetid://131328811362596"
-- Re-send slightly after the server's 0.2s rate limit so a rapid last click
-- is never silently dropped.
local SETTINGS_SAVE_DEBOUNCE_SECONDS = 0.3

local SETTING_ROWS = {
	{ key = PlayerSettings.Keys.MusicEnabled, label = "Music", order = 1 },
	{ key = PlayerSettings.Keys.TreeAutoCollect, label = "Tree Auto-Collect", order = 2 },
	{ key = PlayerSettings.Keys.AcceptGifts, label = "Accept Gifts", order = 3 },
}

local started = false
local settings = PlayerSettings.CopySettings(nil)
local panel = nil
local list = nil
local template = nil
local panelState = nil
local settingsRows = {}
local topbarIcon = nil
local syncingIcon = false
local settingsSaveToken = 0
local tutorialActive = false

local function applyTutorialVisibility()
	if topbarIcon and topbarIcon.enabled == tutorialActive then
		topbarIcon:setEnabled(not tutorialActive)
	end
end

local function findDescendant(root, name, className)
	if not root then
		return nil
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant.Name == name and descendant:IsA(className) then
			return descendant
		end
	end
	return nil
end

local function requireTopbarIcon()
	local satchelRoot = ReplicatedStorage:WaitForChild("Satchel", 10)
	if not satchelRoot then
		warn("[SettingsController] Missing ReplicatedStorage.Satchel; settings toolbar icon will not start")
		return nil
	end

	local loader = satchelRoot:WaitForChild("SatchelLoader", 10)
	local satchelModule = loader and loader:WaitForChild("Satchel", 10)
	local packages = satchelModule and satchelModule:WaitForChild("Packages", 10)
	local topbarPlus = packages and packages:WaitForChild("topbarplus", 10)
	if not topbarPlus then
		warn("[SettingsController] Missing Satchel TopbarPlus module; settings toolbar icon will not start")
		return nil
	end

	return require(topbarPlus)
end

local function sendSettings()
	Remotes.get(Remotes.Names.PlayerSettingsUpdateRequest):FireServer({
		[PlayerSettings.Keys.MusicEnabled] = settings[PlayerSettings.Keys.MusicEnabled] == true,
		[PlayerSettings.Keys.TreeAutoCollect] = settings[PlayerSettings.Keys.TreeAutoCollect] == true,
		[PlayerSettings.Keys.AcceptGifts] = settings[PlayerSettings.Keys.AcceptGifts] == true,
	})
end

local function requestSettings()
	sendSettings()
	settingsSaveToken += 1
	local token = settingsSaveToken
	task.delay(SETTINGS_SAVE_DEBOUNCE_SECONDS, function()
		if settingsSaveToken == token then
			RuntimeGuard.Run("SettingsController.SettingsDebounce", sendSettings)
		end
	end)
end

local function setToggleVisual(row, enabled)
	local on = row and row:FindFirstChild("On")
	local off = row and row:FindFirstChild("Off")
	if on and on:IsA("GuiObject") then
		on.Visible = enabled
	end
	if off and off:IsA("GuiObject") then
		off.Visible = not enabled
	end
end

local function renderSettings()
	for key, row in pairs(settingsRows) do
		setToggleVisual(row, PlayerSettings.Get(settings, key))
	end
end

local function templateRow()
	if template and template.Parent then
		return template
	end
	if not list then
		return nil
	end

	for _, child in ipairs(list:GetChildren()) do
		if child.Name == "Template" and child:IsA("GuiObject") then
			child.Visible = false
			template = child
			break
		end
	end
	return template
end

local function createSettingRow(definition)
	local base = templateRow()
	if not base then
		return nil
	end
	local row = base:Clone()
	row.Name = ROW_NAME_PREFIX .. definition.key
	row.LayoutOrder = definition.order
	row.Visible = true
	row.Parent = list

	local label = row:FindFirstChild("SettingName")
	if label then
		UiEffects.SetTextStack(label, definition.label)
	end

	for _, buttonName in ipairs({ "On", "Off" }) do
		local toggleButton = row:FindFirstChild(buttonName)
		if toggleButton and toggleButton:IsA("GuiButton") then
			toggleButton.Active = true
			toggleButton.Selectable = true
			UiEffects.BindButton(toggleButton)
			RuntimeGuard.Connect(toggleButton.Activated, "SettingsController.SettingActivated", function()
				settings[definition.key] = not PlayerSettings.Get(settings, definition.key)
				renderSettings()
				requestSettings()
			end)
		end
	end

	settingsRows[definition.key] = row
	return row
end

local function ensurePanel()
	if panel and panel.Parent then
		return panel
	end

	panel = MenuGui.GetFrame(PANEL_NAME, "SettingsController")
	if not panel then
		return nil
	end
	list = panel:FindFirstChild("List")
	if not (list and list:IsA("ScrollingFrame")) then
		warn("[SettingsController] Settings is missing List ScrollingFrame")
		return nil
	end
	if not templateRow() then
		warn("[SettingsController] Settings.List is missing Template row")
		return nil
	end
	panelState = UiEffects.PreparePanel(panel)

	local closeButton = findDescendant(panel, "CloseButton", "GuiButton")
	if closeButton then
		closeButton.Active = true
		closeButton.Selectable = true
		UiEffects.BindButton(closeButton)
		RuntimeGuard.Connect(closeButton.Activated, "SettingsController.CloseActivated", function()
			MenuGui.ClosePanel(PANEL_NAME)
		end)
	else
		warn("[SettingsController] Settings is missing CloseButton GuiButton")
	end

	settingsRows = {}
	for _, definition in ipairs(SETTING_ROWS) do
		createSettingRow(definition)
	end
	renderSettings()
	return panel
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

local function openPanel()
	local frame = ensurePanel()
	if not frame then
		return
	end
	renderSettings()
	UiEffects.PlayOpen(frame, panelState)
	syncTopbarIcon(true)
end

local function closePanel()
	if panel then
		UiEffects.PlayClose(panel, panelState)
	end
	syncTopbarIcon(false)
end

function SettingsController.start()
	if started then
		return
	end
	started = true

	local player = Players.LocalPlayer
	player:WaitForChild("PlayerGui")

	MenuGui.RegisterPanel(PANEL_NAME, {
		open = openPanel,
		close = closePanel,
		refresh = renderSettings,
	})

	local function onSettingsChanged(value)
		settings = PlayerSettings.CopySettings(value)
		renderSettings()
	end
	onSettingsChanged(PlayerStateStore.Get(PlayerStateStore.Fields.PlayerSettings))
	PlayerStateStore.Observe(PlayerStateStore.Fields.PlayerSettings, onSettingsChanged)

	local function onOnboardingChanged(state)
		state = Onboarding.SanitizeState(state, Onboarding.CompleteState())
		tutorialActive = Onboarding.IsActive(state.Stage)
		applyTutorialVisibility()
	end
	onOnboardingChanged(PlayerStateStore.Get(PlayerStateStore.Fields.Onboarding))
	PlayerStateStore.Observe(PlayerStateStore.Fields.Onboarding, onOnboardingChanged)

	-- Topbar icon: backpack (-1), index (0), edit (1), media reward (2),
	-- settings (3, always last on the right).
	RuntimeGuard.Spawn("SettingsController.TopbarIcon", function()
		local Icon = requireTopbarIcon()
		if not Icon then
			return
		end
		local icon = Icon.new()
			:setName(TOPBAR_SETTINGS_ICON_NAME)
			:setImage(TOPBAR_SETTINGS_ICON_IMAGE)
			:setImageScale(0.7)
			:setCaption("Settings")
			:setAlignment("Right")
			:setOrder(3)
			:autoDeselect(false)
		icon:modifyTheme({
			{ "IconButton", "BackgroundColor3", Color3.fromRGB(0, 0, 0) },
			{ "IconButton", "BackgroundTransparency", 0.2 },
			{ "IconCorners", "CornerRadius", UDim.new(1, 0) },
			{ "IconSpot", "BackgroundTransparency", 1, "Selected" },
			{ "IconSpotGradient", "Enabled", false, "Selected" },
		})
		RuntimeGuard.Connect(icon.toggled, "SettingsController.IconToggled", function(selected, fromSource)
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
		applyTutorialVisibility()
		-- The panel may already be open/closed by the time the icon resolves.
		syncTopbarIcon(MenuGui.IsOpen(PANEL_NAME))
	end)
end

return SettingsController
