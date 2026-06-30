local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AutoRollConfig = require(Shared:WaitForChild("AutoRollConfig"))
local Rarities = require(Shared:WaitForChild("Rarities"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local StationFocus = require(script.Parent:WaitForChild("StationFocus"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local AutoRollController = {}

local HUD_WAIT_SECONDS = 10
local PROXIMITY_CHECK_SECONDS = 0.1
local SETTINGS_SAVE_DEBOUNCE_SECONDS = AutoRollConfig.RequestRateSeconds + 0.05
local PANEL_NAME = "AutoRollSettings"
local AUTO_PURCHASE_KEY = "__autoPurchase"
local SETTINGS_ROW_NAME_PREFIX = "AutoRollSetting_"
local SILENT_UI_EFFECTS = { silent = true }

local started = false
local serverEnabled = false
local autoPurchase = false
local selectedRarities = {}
local hudFrame = nil
local hudToggle = nil
local hudSettings = nil
local hudPanelState = nil
local hudIsOpen = false
local hudTransitionToken = 0
local panel = nil
local list = nil
local template = nil
local panelState = nil
local settingsRows = {}
local animatedRows = {}
local renderConnection = nil
local settingsSaveToken = 0

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

local function selectedRarityArray()
	local result = {}
	for _, rarity in ipairs(AutoRollConfig.Rarities) do
		if selectedRarities[rarity] == true then
			result[#result + 1] = rarity
		end
	end
	return result
end

local function applySelectedRarityArray(array)
	selectedRarities = {}
	if type(array) ~= "table" then
		return
	end
	for _, rarity in ipairs(array) do
		if type(rarity) == "string" and Rarities.IsValid(rarity) then
			selectedRarities[rarity] = true
		end
	end
end

local function applySettings(settings)
	local clean = AutoRollConfig.CopySettings(settings)
	autoPurchase = clean.autoPurchase == true
	applySelectedRarityArray(clean.selectedRarities)
end

local function autoRollUnlocked()
	local rebirths = tonumber(PlayerStateStore.Get(PlayerStateStore.Fields.Rebirths)) or 0
	return rebirths >= AutoRollConfig.UnlockRebirths
end

local function request(action)
	Remotes.get(Remotes.Names.AutoRollRequest):FireServer({
		action = action,
		autoPurchase = autoPurchase == true,
		selectedRarities = selectedRarityArray(),
	})
end

local function requestSettings()
	request(AutoRollConfig.Actions.Settings)
	settingsSaveToken += 1
	local token = settingsSaveToken
	task.delay(SETTINGS_SAVE_DEBOUNCE_SECONDS, function()
		if settingsSaveToken == token then
			RuntimeGuard.Run("AutoRollController.SettingsDebounce", request, AutoRollConfig.Actions.Settings)
		end
	end)
end

local function disconnectRender()
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
end

local function rowEnabled(key)
	if key == AUTO_PURCHASE_KEY then
		return autoPurchase == true
	end
	return selectedRarities[key] == true
end

local function setToggleVisual(toggleButton, enabled)
	local on = toggleButton and toggleButton:FindFirstChild("On")
	local off = toggleButton and toggleButton:FindFirstChild("Off")
	local status = toggleButton and findDescendant(toggleButton, "StatusTxt", "TextLabel")
	if on and on:IsA("GuiObject") then
		on.Visible = enabled
	end
	if off and off:IsA("GuiObject") then
		off.Visible = not enabled
	end
	if status then
		UiEffects.SetTextStack(status, enabled and "ON" or "OFF")
	end
end

local function colorTextStack(root, color)
	if not root or not color then
		return
	end
	if root:IsA("TextLabel") or root:IsA("TextButton") then
		root.TextColor3 = color
	elseif root:IsA("ImageLabel") or root:IsA("ImageButton") then
		root.ImageColor3 = color
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			descendant.TextColor3 = color
		elseif descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
			descendant.ImageColor3 = color
		end
	end
end

local function applyRarityVisual(row, rarity)
	if not row or not rarity then
		return
	end
	local color = Rarities.ColorFor(rarity, os.clock()) or Rarities.ColorFor(Rarities.Common)
	colorTextStack(row:FindFirstChild("SettingName"), color)
	colorTextStack(row:FindFirstChild("Icon"), color)
end

local function renderSettings()
	for key, row in pairs(settingsRows) do
		local toggleButton = findDescendant(row, "ToggleButton", "GuiButton")
		if toggleButton then
			setToggleVisual(toggleButton, rowEnabled(key))
		end
		if key ~= AUTO_PURCHASE_KEY then
			applyRarityVisual(row, key)
		end
	end
end

local function ensureRenderConnection()
	if renderConnection or next(animatedRows) == nil then
		return
	end
	renderConnection = RuntimeGuard.Connect(RunService.RenderStepped, "AutoRollController.RarityRender", function()
		if not (panel and panel.Parent and panel.Visible) then
			disconnectRender()
			return
		end
		for rarity, row in pairs(animatedRows) do
			applyRarityVisual(row, rarity)
		end
	end)
end

local function openHudPanel()
	if hudIsOpen or not autoRollUnlocked() then
		return
	end
	hudIsOpen = true
	hudTransitionToken += 1
	UiEffects.PlayOpen(hudFrame, hudPanelState, SILENT_UI_EFFECTS)
end

local function closeHudPanel()
	if not hudIsOpen then
		if hudFrame then
			hudFrame.Visible = false
		end
		return
	end
	hudIsOpen = false
	hudTransitionToken += 1
	local token = hudTransitionToken
	UiEffects.PlayClose(hudFrame, hudPanelState, function()
		if hudTransitionToken == token and not hudIsOpen and hudFrame then
			hudFrame.Visible = false
		end
	end, SILENT_UI_EFFECTS)
end

local function renderHud()
	local unlocked = autoRollUnlocked()
	if not unlocked then
		closeHudPanel()
	end
	if hudToggle then
		hudToggle.ImageColor3 = serverEnabled and AutoRollConfig.ToggleColors.On or AutoRollConfig.ToggleColors.Off
		UiEffects.SetButtonEnabled(hudToggle, unlocked)
		hudToggle.AutoButtonColor = false
		hudToggle.Selectable = unlocked
	end
	if hudSettings then
		UiEffects.SetButtonEnabled(hudSettings, unlocked)
		hudSettings.Selectable = unlocked
	end
	if not unlocked and serverEnabled then
		request(AutoRollConfig.Actions.Stop)
	end
	renderSettings()
end

local function templateRow()
	if template and template.Parent then
		return template
	end
	if not list then
		return nil
	end

	local chosen = nil
	for _, child in ipairs(list:GetChildren()) do
		if child.Name == "Template" and child:IsA("GuiObject") then
			child.Visible = false
			if not chosen or child.LayoutOrder < chosen.LayoutOrder then
				chosen = child
			end
		end
	end
	template = chosen
	return template
end

local function setRowName(row, text)
	local label = row and row:FindFirstChild("SettingName")
	if label then
		UiEffects.SetTextStack(label, text)
	end
end

local function createSettingRow(key, text, layoutOrder, rarity)
	local base = templateRow()
	if not base then
		return nil
	end
	local row = base:Clone()
	row.Name = SETTINGS_ROW_NAME_PREFIX .. tostring(key)
	row.LayoutOrder = layoutOrder
	row.Visible = true
	row.Parent = list
	setRowName(row, text)

	local toggleButton = findDescendant(row, "ToggleButton", "GuiButton")
	if toggleButton then
		toggleButton.Active = true
		toggleButton.Selectable = true
		UiEffects.BindButton(toggleButton)
		RuntimeGuard.Connect(toggleButton.Activated, "AutoRollController.SettingActivated", function()
			if key == AUTO_PURCHASE_KEY then
				autoPurchase = not autoPurchase
			else
				selectedRarities[key] = selectedRarities[key] ~= true
			end
			renderSettings()
			requestSettings()
		end)
	end

	settingsRows[key] = row
	local definition = rarity and Rarities.Get(rarity) or nil
	if definition and definition.Animated == true then
		animatedRows[rarity] = row
	end
	if rarity then
		applyRarityVisual(row, rarity)
	end
	return row
end

local function ensurePanel()
	if panel and panel.Parent then
		return panel
	end

	panel = MenuGui.GetFrame(PANEL_NAME, "AutoRollController")
	if not panel then
		return nil
	end
	list = panel:FindFirstChild("List")
	if not (list and list:IsA("ScrollingFrame")) then
		warn("[AutoRollController] AutoRollSettings is missing List ScrollingFrame")
		return nil
	end
	template = templateRow()
	if not template then
		warn("[AutoRollController] AutoRollSettings.List is missing Template row")
		return nil
	end
	panelState = UiEffects.PreparePanel(panel)

	local closeButton = findDescendant(panel, "CloseButton", "GuiButton")
	if closeButton then
		closeButton.Active = true
		closeButton.Selectable = true
		UiEffects.BindButton(closeButton)
		RuntimeGuard.Connect(closeButton.Activated, "AutoRollController.CloseActivated", function()
			MenuGui.ClosePanel(PANEL_NAME)
		end)
	else
		warn("[AutoRollController] AutoRollSettings is missing CloseButton GuiButton")
	end

	settingsRows = {}
	animatedRows = {}
	createSettingRow(AUTO_PURCHASE_KEY, "Auto Purchase ON/Enabled", 0, nil)
	for index, rarity in ipairs(AutoRollConfig.Rarities) do
		createSettingRow(rarity, rarity, index + 3, rarity)
	end
	renderSettings()
	return panel
end

local function openPanel()
	local frame = ensurePanel()
	if not frame then
		return
	end
	renderSettings()
	ensureRenderConnection()
	UiEffects.PlayOpen(frame, panelState)
end

local function closePanel()
	disconnectRender()
	if panel then
		UiEffects.PlayClose(panel, panelState)
	end
end

function AutoRollController.start()
	if started then
		return
	end
	started = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local hud = playerGui:WaitForChild("HUD", HUD_WAIT_SECONDS)
	if not hud then
		warn("[AutoRollController] Missing PlayerGui.HUD")
		return
	end
	local rollButtons = hud:WaitForChild("RollButtons", HUD_WAIT_SECONDS)
	if not (rollButtons and rollButtons:IsA("GuiObject")) then
		warn("[AutoRollController] Missing HUD.RollButtons")
		return
	end

	hudFrame = rollButtons:WaitForChild("AutoRoll", HUD_WAIT_SECONDS)
	if not (hudFrame and hudFrame:IsA("GuiObject")) then
		warn("[AutoRollController] Missing HUD.RollButtons.AutoRoll")
		return
	end
	hudToggle = hudFrame:FindFirstChild("Toggle")
	hudSettings = hudFrame:FindFirstChild("Settings")
	if not (hudToggle and hudToggle:IsA("ImageButton") and hudSettings and hudSettings:IsA("ImageButton")) then
		warn("[AutoRollController] AutoRoll HUD is missing Toggle or Settings ImageButton")
		return
	end
	hudPanelState = UiEffects.PreparePanel(hudFrame)

	hudToggle.AutoButtonColor = false
	hudToggle.Active = false
	hudToggle.Selectable = false
	hudSettings.Active = false
	hudSettings.Selectable = false
	UiEffects.BindButton(hudToggle, {
		colorTween = false,
	})
	UiEffects.BindButton(hudSettings, {
		colorTween = false,
	})
	RuntimeGuard.Connect(hudToggle.Activated, "AutoRollController.ToggleActivated", function()
		if not autoRollUnlocked() then
			UiEffects.PlayError()
			return
		end
		request(serverEnabled and AutoRollConfig.Actions.Stop or AutoRollConfig.Actions.Start)
	end)
	RuntimeGuard.Connect(hudSettings.Activated, "AutoRollController.SettingsActivated", function()
		if not autoRollUnlocked() then
			UiEffects.PlayError()
			return
		end
		MenuGui.OpenPanel(PANEL_NAME)
	end)

	MenuGui.RegisterPanel(PANEL_NAME, {
		open = openPanel,
		close = closePanel,
		refresh = function()
			renderSettings()
		end,
	})

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.AutoRollState).OnClientEvent, "AutoRollController.AutoRollState", function(payload)
		if type(payload) ~= "table" then
			return
		end
		serverEnabled = payload.enabled == true
		if type(payload.selectedRarities) == "table" then
			applySettings(payload)
		end
		if not serverEnabled
			and payload.code ~= nil
			and payload.code ~= "ok"
			and payload.code ~= "stopped"
			and payload.code ~= "selected-rarity" then
			UiEffects.PlayError()
		end
		renderHud()
	end)

	PlayerStateStore.Observe(PlayerStateStore.Fields.Rebirths, renderHud)
	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, renderHud)
	PlayerStateStore.Observe(PlayerStateStore.Fields.AutoRollSettings, function(settings)
		applySettings(settings)
		renderHud()
	end)
	RuntimeGuard.Spawn("AutoRollController.ProximityLoop", function()
		while hudFrame.Parent do
			RuntimeGuard.Run("AutoRollController.ProximityTick", function()
				if autoRollUnlocked() and StationFocus.IsRollActive() then
					openHudPanel()
				else
					closeHudPanel()
				end
				renderHud()
			end)
			task.wait(PROXIMITY_CHECK_SECONDS)
		end
	end)
	renderHud()
end

return AutoRollController
