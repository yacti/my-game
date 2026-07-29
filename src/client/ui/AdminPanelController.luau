-- Owner-only admin panel (ReplicatedStorage.UI.Menu.AdminPanel). Pure
-- presentation: the panel opens only while AdminPanelService has armed it
-- (player attribute set from the server command bar), and every button just
-- sends one AdminPanelCommandRequest that the server re-validates against its
-- owner allowlist. Sections:
--
--   OwnerMessage / AlienMessage  -> global HUD message (Owner / Alien preset);
--                                   submits ONLY via the GO button
--   LuckAmount                   -> pick a multiplier + compose a duration,
--                                   preview in LuckPreview, CONFIRM applies
--                                   globally (replace semantics)
--   AdminEvents                  -> global Alien start/stop
--   PadToggle                    -> admin party pad on/off (all servers)
--   CrateDrops                   -> one-shot admin crate drops (luck crates
--                                   plus the Secret/Mythic rarity-pool blocks)
--   Pinata                       -> one-shot pinata spawn (Default / Golden,
--                                   one per press, every server) and a global
--                                   CLEAR that removes them with no payout
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AdminPanelConfig = require(Shared:WaitForChild("AdminPanelConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local AdminPanelController = {}

local PANEL_NAME = "AdminPanel"
local REQUEST_TIMEOUT_SECONDS = 30
local MAX_MESSAGE_TEXT_BYTES = 180 -- mirror of the control-plane cap
local SELECTED_TEXT_COLOR = Color3.fromRGB(255, 200, 60)

local Actions = AdminPanelConfig.Actions

local requestRemote = Remotes.get(Remotes.Names.AdminPanelCommandRequest)
local resultRemote = Remotes.get(Remotes.Names.AdminPanelCommandResult)

local selectedMultiplier = nil
local durationSeconds = 0
-- True while the luck row is in "remove" mode: preview reads LUCK REMOVED and
-- CONFIRM pushes a global StopAdminLuck instead of a new boost.
local removalPending = false
local nextRequestId = 0
local pendingRequestId = nil
local pendingContext = nil
local timeoutToken = 0
local renderAll = nil
local actionButtons = {}
local multiplierTextLabels = {}

local function child(parent, name, className)
	local found = parent and parent:FindFirstChild(name)
	if found and (not className or found:IsA(className)) then
		return found
	end
	return nil
end

local function section(panel, name)
	local frame = child(panel, name, "Frame")
	if not frame then
		warn("[AdminPanelController] Missing AdminPanel.Panel." .. name .. "; section skipped")
	end
	return frame
end

local function trackButton(button)
	actionButtons[#actionButtons + 1] = button
	UiEffects.BindButton(button)
end

local function formatDuration(seconds)
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	if hours > 0 and minutes > 0 then
		return string.format("%d hr %d min", hours, minutes)
	elseif hours > 0 then
		return string.format("%d hr", hours)
	end
	return string.format("%d min", minutes)
end

local function canConfirmLuck()
	return removalPending or (selectedMultiplier ~= nil and durationSeconds > 0)
end

local function send(action, extra, context)
	if pendingRequestId ~= nil then
		return
	end
	nextRequestId += 1
	pendingRequestId = nextRequestId
	pendingContext = context

	local payload = { requestId = pendingRequestId, action = action }
	if type(extra) == "table" then
		for key, value in pairs(extra) do
			payload[key] = value
		end
	end
	requestRemote:FireServer(payload)

	-- The server always replies (fail-closed codes), but never leave the
	-- panel dead if that reply is lost.
	timeoutToken += 1
	local token = timeoutToken
	local requestId = pendingRequestId
	task.delay(REQUEST_TIMEOUT_SECONDS, function()
		if token == timeoutToken and pendingRequestId == requestId then
			pendingRequestId = nil
			pendingContext = nil
			if renderAll then
				renderAll()
			end
		end
	end)

	if renderAll then
		renderAll()
	end
end

local function bindMessageSection(frame, action)
	local textBox = child(frame, "TextBox", "TextBox")
	local enterButton = child(frame, "Enter", "ImageButton")
	if not (textBox and enterButton) then
		warn("[AdminPanelController] Message section is missing TextBox or Enter; skipped")
		return
	end
	textBox.ClearTextOnFocus = false

	trackButton(enterButton)
	-- Submit ONLY via the GO button: no FocusLost/keyboard-Enter binding on
	-- purpose, so a stray Enter can never broadcast a half-typed message.
	RuntimeGuard.Connect(enterButton.Activated, "AdminPanelController.Send" .. action, function()
		local text = string.match(textBox.Text, "^%s*(.-)%s*$")
		if text == "" or #text > MAX_MESSAGE_TEXT_BYTES then
			UiEffects.PlayError()
			return
		end
		send(action, { text = text }, { textBox = textBox })
	end)
end

local function bindLuckSection(frame)
	local previewLabel = child(frame, "LuckPreview", "TextLabel")
	local confirmButton = child(frame, "CONFIRM", "ImageButton")
	if not (previewLabel and confirmButton) then
		warn("[AdminPanelController] LuckAmount is missing LuckPreview or CONFIRM; skipped")
		return nil
	end

	local function renderLuck()
		for multiplier, textLabel in pairs(multiplierTextLabels) do
			textLabel.TextColor3 = multiplier == selectedMultiplier and SELECTED_TEXT_COLOR or Color3.new(1, 1, 1)
		end
		if removalPending then
			UiEffects.SetTextStack(previewLabel, "LUCK REMOVED")
		elseif canConfirmLuck() then
			UiEffects.SetTextStack(previewLabel, string.format("x%d luck %s", selectedMultiplier, formatDuration(durationSeconds)))
		else
			UiEffects.SetTextStack(previewLabel, "pick luck + time")
		end
		UiEffects.SetButtonEnabled(confirmButton, canConfirmLuck() and pendingRequestId == nil)
	end

	for _, multiplier in ipairs(AdminPanelConfig.AllowedLuckMultipliers) do
		local button = child(frame, tostring(multiplier) .. "xLuck", "ImageButton")
		local textLabel = button and button:FindFirstChild("Text")
		if button and textLabel and textLabel:IsA("TextLabel") then
			multiplierTextLabels[multiplier] = textLabel
			trackButton(button)
			RuntimeGuard.Connect(button.Activated, "AdminPanelController.PickLuck" .. multiplier, function()
				removalPending = false
				selectedMultiplier = multiplier
				renderLuck()
			end)
		else
			warn(string.format("[AdminPanelController] Missing LuckAmount.%dxLuck button", multiplier))
		end
	end

	local timeSteps = {
		{ name = "Plus30Min", delta = AdminPanelConfig.LuckSmallStepSeconds },
		{ name = "Plus6Hr", delta = AdminPanelConfig.LuckLargeStepSeconds },
	}
	for _, step in ipairs(timeSteps) do
		local button = child(frame, step.name, "ImageButton")
		if button then
			trackButton(button)
			RuntimeGuard.Connect(button.Activated, "AdminPanelController.Time" .. step.name, function()
				removalPending = false
				durationSeconds = math.clamp(durationSeconds + step.delta, 0, AdminPanelConfig.MaxLuckDurationSeconds)
				renderLuck()
			end)
		else
			warn("[AdminPanelController] Missing LuckAmount." .. step.name .. " button")
		end
	end

	-- Remove mode: clears any composed boost, previews LUCK REMOVED, and
	-- CONFIRM pushes the global stop. Doubles as a reset for a mis-composed
	-- boost (tap REMOVE, then pick again).
	local removeButton = child(frame, "RemoveLuck", "ImageButton")
	if removeButton then
		trackButton(removeButton)
		RuntimeGuard.Connect(removeButton.Activated, "AdminPanelController.RemoveLuck", function()
			removalPending = true
			selectedMultiplier = nil
			durationSeconds = 0
			renderLuck()
		end)
	else
		warn("[AdminPanelController] Missing LuckAmount.RemoveLuck button")
	end

	trackButton(confirmButton)
	RuntimeGuard.Connect(confirmButton.Activated, "AdminPanelController.ConfirmLuck", function()
		if not canConfirmLuck() then
			UiEffects.PlayError()
			return
		end
		if removalPending then
			send(Actions.RemoveAdminLuck, nil, { isLuck = true })
			return
		end
		send(Actions.SetAdminLuck, {
			multiplier = selectedMultiplier,
			durationSeconds = durationSeconds,
		}, { isLuck = true })
	end)

	return renderLuck
end

local function bindSimpleButton(frame, buttonName, action, extra)
	local button = child(frame, buttonName, "ImageButton")
	if not button then
		warn("[AdminPanelController] Missing button " .. buttonName .. "; skipped")
		return
	end
	trackButton(button)
	RuntimeGuard.Connect(button.Activated, "AdminPanelController." .. buttonName, function()
		send(action, extra)
	end)
end

local function bindPanel(panelFrame)
	local panel = child(panelFrame, "Panel", "Frame")
	if not panel then
		warn("[AdminPanelController] Missing AdminPanel.Panel; admin panel disabled")
		return false
	end

	local closeButton = child(panel, "CloseButton", "ImageButton")
	if closeButton then
		UiEffects.BindButton(closeButton)
		RuntimeGuard.Connect(closeButton.Activated, "AdminPanelController.Close", function()
			MenuGui.ClosePanel(PANEL_NAME)
		end)
	end

	local ownerMessage = section(panel, "OwnerMessage")
	if ownerMessage then
		bindMessageSection(ownerMessage, Actions.SendOwnerMessage)
	end
	local alienMessage = section(panel, "AlienMessage")
	if alienMessage then
		bindMessageSection(alienMessage, Actions.SendAlienMessage)
	end

	local renderLuck = nil
	local luckAmount = section(panel, "LuckAmount")
	if luckAmount then
		renderLuck = bindLuckSection(luckAmount)
	end

	local adminEvents = section(panel, "AdminEvents")
	if adminEvents then
		bindSimpleButton(adminEvents, "AlienStart", Actions.AlienStart)
		bindSimpleButton(adminEvents, "AlienStop", Actions.AlienStop)
	end

	local padToggle = section(panel, "PadToggle")
	if padToggle then
		bindSimpleButton(padToggle, "PadOn", Actions.PadOn)
		bindSimpleButton(padToggle, "PadOff", Actions.PadOff)
	end

	local crateDrops = section(panel, "CrateDrops")
	if crateDrops then
		-- Button names double as RollChances.AdminCrates ids.
		for _, crateId in ipairs({ "InfernoCrate", "SaturnCrate", "UFOCrate", "MythicLuckyBlock", "SecretLuckyBlock" }) do
			bindSimpleButton(crateDrops, crateId, Actions.DropCrate, { crateId = crateId })
		end
	end

	local pinata = section(panel, "Pinata")
	if pinata then
		-- One press spawns one pinata on every server, at that server's own
		-- free spawn slot. The server re-validates the variant.
		for _, entry in ipairs(AdminPanelConfig.PinataButtons) do
			bindSimpleButton(pinata, entry.button, Actions.SpawnPinata, { variant = entry.variant })
		end
		bindSimpleButton(pinata, "ClearAll", Actions.ClearPinatas)
	end

	renderAll = function()
		local busy = pendingRequestId ~= nil
		for _, button in ipairs(actionButtons) do
			UiEffects.SetButtonEnabled(button, not busy)
		end
		if renderLuck then
			renderLuck()
		end
	end
	renderAll()
	return true
end

function AdminPanelController.start()
	local player = Players.LocalPlayer

	local panelFrame = MenuGui.GetFrame(PANEL_NAME, "AdminPanelController")
	if not panelFrame then
		return
	end
	if not bindPanel(panelFrame) then
		return
	end

	MenuGui.RegisterPanel(PANEL_NAME, {
		-- Utility overlay: no blur, no camera zoom, no HUD hiding.
		effects = false,
		close = function()
			panelFrame.Visible = false
			-- Closing locally (X / switching menus) disarms the panel so the
			-- server gate always matches what is on screen. When the server
			-- disarmed first, the attribute is already false: send nothing.
			if player:GetAttribute(State.AdminPanel.Enabled) == true then
				requestRemote:FireServer({ action = Actions.ClosePanel })
			end
		end,
	})

	local function syncFromAttribute()
		if player:GetAttribute(State.AdminPanel.Enabled) == true then
			MenuGui.OpenPanel(PANEL_NAME)
		else
			MenuGui.ClosePanel(PANEL_NAME)
		end
	end
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.AdminPanel.Enabled), "AdminPanelController.EnabledChanged", syncFromAttribute)
	syncFromAttribute()

	RuntimeGuard.Connect(resultRemote.OnClientEvent, "AdminPanelController.Result", function(payload)
		if type(payload) ~= "table" or payload.requestId ~= pendingRequestId then
			return
		end
		local context = pendingContext
		pendingRequestId = nil
		pendingContext = nil
		if payload.ok == true and type(context) == "table" then
			if context.textBox then
				context.textBox.Text = ""
			end
			if context.isLuck then
				selectedMultiplier = nil
				durationSeconds = 0
				removalPending = false
			end
		end
		if renderAll then
			renderAll()
		end
	end)
end

return AdminPanelController
