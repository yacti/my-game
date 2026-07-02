local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))

local JoinBackShowcaseController = {}

local HUD_NAME = "HUD"
local LOADING_SCREEN_NAME = "LoadingScreen"
local TEXT_FRAME_NAME = "JoinBackText"
local TEXT_LABEL_NAME = "JoinBackText"
local FLASH_NAME = "JoinBackFlash"
local TOP_BAR_NAME = "TopBar"
local NOTIFICATIONS_NAME = "Notifications"

local PRE_SEQUENCE_DELAY = 1
local BEFORE_MESSAGE_SECONDS = 3
local POST_MESSAGE_SECONDS = 3
local APPLIED_WAIT_TIMEOUT = 2

local TEXT_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FLASH_IN_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FLASH_OUT_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local MESSAGES = {
	before = "Last time you played, your farm looked like this...",
	now = "Now your farm looks like this!",
}

local STARTABLE_PHASES = {
	pending = true,
	started = true,
}

local started = false

local function findGuiObject(root, name)
	local found = root and root:FindFirstChild(name, true)
	return found and found:IsA("GuiObject") and found or nil
end

local function findTextLabel(frame)
	local label = frame and frame:FindFirstChild(TEXT_LABEL_NAME, true)
	return label and label:IsA("TextLabel") and label or nil
end

local function playTween(instance, tweenInfo, props)
	local tween = TweenService:Create(instance, tweenInfo, props)
	tween:Play()
	tween.Completed:Wait()
	return tween
end

local function waitForLoadingScreenDismissed(playerGui)
	local existing = playerGui:FindFirstChild(LOADING_SCREEN_NAME)
	if not existing then
		return
	end

	while playerGui:FindFirstChild(LOADING_SCREEN_NAME) do
		local removed = playerGui.ChildRemoved:Wait()
		if removed.Name == LOADING_SCREEN_NAME then
			return
		end
	end
end

local function waitForPhase(seq, phase, timeoutSeconds)
	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		local state = PlayerStateStore.Get(PlayerStateStore.Fields.JoinBackShowcase)
		if type(state) == "table" and state.seq == seq and state.phase == phase then
			return true
		end
		task.wait(0.1)
	end
	return false
end

local function setText(textFrame, textLabel, text)
	if not (textFrame and textLabel) then
		return
	end
	textLabel.Text = text
	textLabel.TextTransparency = 1
	textFrame.Visible = true
	playTween(textLabel, TEXT_TWEEN, { TextTransparency = 0 })
end

local function flashToWhite(flashFrame)
	if not flashFrame then
		return false
	end
	flashFrame.BackgroundTransparency = 1
	flashFrame.Visible = true
	playTween(flashFrame, FLASH_IN_TWEEN, { BackgroundTransparency = 0 })
	return true
end

local function fadeFlashOut(flashFrame)
	if not flashFrame then
		return
	end
	playTween(flashFrame, FLASH_OUT_TWEEN, { BackgroundTransparency = 1 })
	flashFrame.Visible = false
end

local function rememberVisibility(objects)
	local records = {}
	for _, object in ipairs(objects) do
		if object then
			local record = {
				object = object,
				visible = object.Visible,
			}
			record.connection = RuntimeGuard.Connect(
				object:GetPropertyChangedSignal("Visible"),
				"JoinBackShowcaseController.HoldHidden." .. object.Name,
				function()
					if object.Parent and object.Visible then
						object.Visible = false
					end
				end
			)
			object.Visible = false
			records[#records + 1] = record
		end
	end
	return records
end

local function restoreVisibility(records)
	for _, record in ipairs(records) do
		local connection = record.connection
		if connection then
			connection:Disconnect()
		end
	end
	for _, record in ipairs(records) do
		local object = record.object
		local visible = record.visible
		if object.Parent then
			object.Visible = visible
		end
	end
end

local function runSequence(playerGui, requestRemote, payload)
	local seq = payload.seq
	local hud = playerGui:WaitForChild(HUD_NAME, 10)
	if not hud then
		warn("[JoinBackShowcaseController] Missing HUD ScreenGui")
		requestRemote:FireServer("showcaseStarted", seq)
		requestRemote:FireServer("flashComplete", seq)
		return
	end

	local textFrame = findGuiObject(hud, TEXT_FRAME_NAME)
	local textLabel = findTextLabel(textFrame)
	local flashFrame = findGuiObject(hud, FLASH_NAME)
	if textFrame then
		textFrame.Visible = false
	end
	if flashFrame then
		flashFrame.Visible = false
	else
		warn("[JoinBackShowcaseController] Missing HUD.JoinBackFlash GuiObject")
	end
	if not (textFrame and textLabel) then
		warn("[JoinBackShowcaseController] Missing HUD.JoinBackText.JoinBackText TextLabel")
	end

	waitForLoadingScreenDismissed(playerGui)

	local hidden = rememberVisibility({
		findGuiObject(hud, TOP_BAR_NAME),
		findGuiObject(hud, NOTIFICATIONS_NAME),
	})

	local cleanupRan = false
	local function cleanup()
		if cleanupRan then
			return
		end
		cleanupRan = true
		if textFrame then
			textFrame.Visible = false
		end
		if flashFrame then
			flashFrame.Visible = false
			flashFrame.BackgroundTransparency = 1
		end
		restoreVisibility(hidden)
	end

	local ok = RuntimeGuard.Run("JoinBackShowcaseController.Sequence", function()
		task.wait(PRE_SEQUENCE_DELAY)
		requestRemote:FireServer("showcaseStarted", seq)
		setText(textFrame, textLabel, MESSAGES.before)
		task.wait(BEFORE_MESSAGE_SECONDS)
		local flashedToWhite = flashToWhite(flashFrame)
		requestRemote:FireServer("flashComplete", seq)
		waitForPhase(seq, "applied", APPLIED_WAIT_TIMEOUT)
		if flashedToWhite then
			task.wait(0.08)
			fadeFlashOut(flashFrame)
		end
		setText(textFrame, textLabel, MESSAGES.now)
		task.wait(POST_MESSAGE_SECONDS)
		requestRemote:FireServer("clientComplete", seq)
	end)

	cleanup()
	if ok ~= true then
		requestRemote:FireServer("flashComplete", seq)
	end
end

function JoinBackShowcaseController.start()
	if started then return end
	started = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local requestRemote = Remotes.get(Remotes.Names.JoinBackShowcaseRequest)
	local activeSeq = nil

	PlayerStateStore.Observe(PlayerStateStore.Fields.JoinBackShowcase, function(payload)
		if type(payload) ~= "table" then
			return
		end
		local seq = tonumber(payload.seq)
		if not seq or seq == activeSeq or STARTABLE_PHASES[payload.phase] ~= true then
			return
		end
		activeSeq = seq
		task.spawn(function()
			runSequence(playerGui, requestRemote, payload)
			if activeSeq == seq then
				activeSeq = nil
			end
		end)
	end)
end

return JoinBackShowcaseController
