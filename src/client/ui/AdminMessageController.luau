-- Renders global admin messages (ReplicatedStorage.AdminMessages, published by
-- LiveEventCommandService) into the Studio-authored HUD.AdminText frames.
--
-- Display rules: sequential queue, newest at the bottom (LayoutOrder), each
-- message shows for AdminMessagePresets.DisplaySeconds with a typewriter
-- reveal, then tweens out. At most MaxVisible messages on screen; the oldest
-- is forced out when a new one arrives at the cap. Messages are hidden during
-- the tutorial and shown afterwards if their receivable window is still open.
-- Each messageId displays at most once per client.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AdminMessagePresets = require(Shared:WaitForChild("AdminMessagePresets"))
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))

local AdminMessageController = {}

local HUD_NAME = "HUD"
local ADMIN_TEXT_NAME = "AdminText"
local TEXT_LABEL_NAME = "NotificationTemplate"
local FOLDER_WAIT_SECONDS = 30
local FADE_SECONDS = 0.35
local TYPE_SECONDS_PER_GRAPHEME = 0.04
local MAX_TYPE_SECONDS = 2.5

local PENDING_SWEEP_SECONDS = 5

local player = Players.LocalPlayer
local started = false
local warned = {}
local templatesHidden = false
local seenMessageIds = {}
local pendingRecords = {}
local visibleDisplays = {}
local layoutOrderNext = 1

local function warnOnce(key, message)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[AdminMessageController] " .. message)
end

-- Read the tutorial gate from the replica store at display time rather than
-- caching a flag; a cached flag can wedge on notify-ordering races. Replica
-- not loaded yet counts as active (hold the message).
local function isOnboardingActive()
	local state = PlayerStateStore.Get(PlayerStateStore.Fields.Onboarding)
	if type(state) ~= "table" then
		return true
	end
	local sanitized = Onboarding.SanitizeState(state, Onboarding.CompleteState())
	return Onboarding.IsActive(sanitized.Stage)
end

local function serverNow()
	return Workspace:GetServerTimeNow()
end

local function resolveAdminText()
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local hud = playerGui and playerGui:FindFirstChild(HUD_NAME)
	local adminText = hud and hud:FindFirstChild(ADMIN_TEXT_NAME)
	if not (adminText and adminText:IsA("GuiObject")) then
		warnOnce("adminText", "Missing PlayerGui.HUD.AdminText; admin messages skipped")
		return nil
	end

	local templates = {}
	for _, child in ipairs(adminText:GetChildren()) do
		if child:IsA("GuiObject") then
			templates[child.Name] = child
			if not templatesHidden then
				child.Visible = false
			end
		end
	end
	templatesHidden = true
	return adminText, templates
end

local function readRecord(child)
	if not child then
		return nil
	end
	local presetId = child:GetAttribute(State.AdminMessage.PresetId)
	local text = child:GetAttribute(State.AdminMessage.Text)
	local startsAt = tonumber(child:GetAttribute(State.AdminMessage.StartsAt))
	local endsAt = tonumber(child:GetAttribute(State.AdminMessage.EndsAt))
	if type(presetId) ~= "string" or type(text) ~= "string" or text == "" or not startsAt or not endsAt then
		return nil
	end
	return {
		messageId = child.Name,
		presetId = presetId,
		text = text,
		startsAt = startsAt,
		endsAt = endsAt,
	}
end

local function fadeTargets(frame)
	local targets = {}
	local function collect(instance)
		if instance:IsA("TextLabel") then
			targets[#targets + 1] = { instance = instance, props = { TextTransparency = 1, TextStrokeTransparency = 1 } }
		elseif instance:IsA("ImageLabel") then
			targets[#targets + 1] = { instance = instance, props = { ImageTransparency = 1 } }
		elseif instance:IsA("UIStroke") then
			targets[#targets + 1] = { instance = instance, props = { Transparency = 1 } }
		end
	end
	collect(frame)
	for _, descendant in ipairs(frame:GetDescendants()) do
		collect(descendant)
	end
	return targets
end

local function removeDisplay(display)
	for index, current in ipairs(visibleDisplays) do
		if current == display then
			table.remove(visibleDisplays, index)
			break
		end
	end
end

local function fadeOutDisplay(display)
	if display.fading then
		return
	end
	display.fading = true

	local frame = display.frame
	if not (frame and frame.Parent) then
		removeDisplay(display)
		return
	end
	local tweenInfo = TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, target in ipairs(fadeTargets(frame)) do
		TweenService:Create(target.instance, tweenInfo, target.props):Play()
	end
	task.delay(FADE_SECONDS + 0.05, function()
		RuntimeGuard.Run("AdminMessageController.DestroyDisplay", function()
			removeDisplay(display)
			if frame.Parent then
				frame:Destroy()
			end
		end)
	end)
end

local function playTypewriter(textLabel, text)
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

local function showRecord(record)
	if seenMessageIds[record.messageId] then
		return
	end
	if record.endsAt <= serverNow() then
		return
	end
	if isOnboardingActive() then
		pendingRecords[record.messageId] = record
		return
	end
	pendingRecords[record.messageId] = nil

	local preset = AdminMessagePresets.Get(record.presetId)
	if not preset then
		warnOnce("preset-" .. tostring(record.presetId), "Unknown admin message preset " .. tostring(record.presetId))
		return
	end
	local container, templates = resolveAdminText()
	if not container then
		return
	end
	local template = templates[preset.frameName]
	if not template then
		warnOnce("frame-" .. tostring(preset.frameName), "HUD.AdminText is missing the " .. tostring(preset.frameName) .. " frame")
		return
	end

	local frame = template:Clone()
	local textLabel = frame:FindFirstChild(TEXT_LABEL_NAME)
	if not (textLabel and textLabel:IsA("TextLabel")) then
		warnOnce("text-" .. tostring(preset.frameName), "AdminText." .. tostring(preset.frameName) .. " is missing " .. TEXT_LABEL_NAME)
		frame:Destroy()
		return
	end
	local nameLabel = frame:FindFirstChild(preset.frameName .. "Name")
	local imageLabel = frame:FindFirstChild(preset.frameName .. "Image")

	if preset.displayName and nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = preset.displayName
	end
	if preset.nameColor and nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.TextColor3 = preset.nameColor
	end
	if preset.image and imageLabel and imageLabel:IsA("ImageLabel") then
		imageLabel.Image = preset.image
	end
	if preset.textColor then
		textLabel.TextColor3 = preset.textColor
	end
	textLabel.Text = record.text

	frame.Name = record.messageId
	frame.LayoutOrder = layoutOrderNext
	layoutOrderNext += 1
	frame.Visible = true
	frame.Parent = container

	seenMessageIds[record.messageId] = true
	local display = {
		messageId = record.messageId,
		frame = frame,
		fading = false,
	}
	visibleDisplays[#visibleDisplays + 1] = display

	-- Force the oldest out when over the cap.
	while #visibleDisplays > AdminMessagePresets.MaxVisible do
		local oldest = visibleDisplays[1]
		fadeOutDisplay(oldest)
		removeDisplay(oldest)
	end

	playTypewriter(textLabel, record.text)
	task.delay(AdminMessagePresets.DisplaySeconds, function()
		RuntimeGuard.Run("AdminMessageController.ExpireDisplay", fadeOutDisplay, display)
	end)
end

local function flushPending()
	local records = {}
	for _, record in pairs(pendingRecords) do
		records[#records + 1] = record
	end
	table.sort(records, function(left, right)
		if left.startsAt ~= right.startsAt then
			return left.startsAt < right.startsAt
		end
		return left.messageId < right.messageId
	end)
	-- Only surface the newest few so a long tutorial doesn't dump a backlog.
	for index = math.max(#records - AdminMessagePresets.MaxVisible + 1, 1), #records do
		showRecord(records[index])
	end
	pendingRecords = {}
end

local function flushPendingIfEligible()
	if next(pendingRecords) ~= nil and not isOnboardingActive() then
		flushPending()
	end
end

local function onChildRemoved(child)
	local messageId = child.Name
	pendingRecords[messageId] = nil
	-- Normal expiry removal happens well after the display window; an early
	-- removal is a ClearGlobalMessages, so hide immediately.
	for _, display in ipairs(visibleDisplays) do
		if display.messageId == messageId then
			fadeOutDisplay(display)
			return
		end
	end
end

local function bindFolder()
	local folder = ReplicatedStorage:WaitForChild(AdminMessagePresets.FolderName, FOLDER_WAIT_SECONDS)
	if not folder then
		warnOnce("folder", "Missing ReplicatedStorage." .. AdminMessagePresets.FolderName .. "; admin messages disabled")
		return
	end

	RuntimeGuard.Connect(folder.ChildAdded, "AdminMessageController.ChildAdded", function(child)
		local record = readRecord(child)
		if record then
			showRecord(record)
		end
	end)
	RuntimeGuard.Connect(folder.ChildRemoved, "AdminMessageController.ChildRemoved", onChildRemoved)

	-- Join-time scan: show only the newest unexpired few, oldest first so
	-- LayoutOrder matches chronology.
	local now = serverNow()
	local records = {}
	for _, child in ipairs(folder:GetChildren()) do
		local record = readRecord(child)
		if record and record.endsAt > now then
			records[#records + 1] = record
		end
	end
	table.sort(records, function(left, right)
		if left.startsAt ~= right.startsAt then
			return left.startsAt < right.startsAt
		end
		return left.messageId < right.messageId
	end)
	for index = math.max(#records - AdminMessagePresets.MaxVisible + 1, 1), #records do
		showRecord(records[index])
	end
end

function AdminMessageController.start()
	if started then
		return
	end
	started = true

	PlayerStateStore.Observe(PlayerStateStore.Fields.Onboarding, flushPendingIfEligible)
	-- Belt-and-braces: retry held messages periodically so a missed replica
	-- notify can only delay them, never wedge them; also drop expired holds.
	RuntimeGuard.Spawn("AdminMessageController.PendingSweep", function()
		while true do
			task.wait(PENDING_SWEEP_SECONDS)
			local now = serverNow()
			for messageId, record in pairs(pendingRecords) do
				if record.endsAt <= now then
					pendingRecords[messageId] = nil
				end
			end
			flushPendingIfEligible()
		end
	end)

	-- Hide the authored template frames as soon as the HUD exists.
	resolveAdminText()

	RuntimeGuard.Spawn("AdminMessageController.BindFolder", bindFolder)
end

return AdminMessageController
