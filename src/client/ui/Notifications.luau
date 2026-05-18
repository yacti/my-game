local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))

local Notifications = {}

local HUD_NAME = "HUD"
local CONTAINER_NAME = "Notifications"
local ITEM_TEMPLATE_NAME = "NotificationTemplate"
local SHOW_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HIDE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local started = false
local container = nil
local template = nil
local active = {}

local function findContainer(hud)
	local found = hud:FindFirstChild(CONTAINER_NAME, true)
	if not (found and found:IsA("GuiObject")) then
		warn("[Notifications] HUD UI missing Notifications GuiObject")
		return nil
	end
	return found
end

local function findItemTemplate(guiContainer)
	local found = guiContainer:FindFirstChild(ITEM_TEMPLATE_NAME, true)
	if not (found and found:IsA("TextLabel")) then
		warn("[Notifications] Notifications UI missing NotificationTemplate TextLabel")
		return nil
	end
	return found
end

local function ensureListLayout(guiContainer)
	local layout = guiContainer:FindFirstChildOfClass("UIListLayout")
	if not layout then
		warn("[Notifications] Notifications container missing UIListLayout")
		return nil
	end
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	return layout
end

local function applyItemStyle(label, payload)
	label.Text = payload.text
	label.TextColor3 = NotificationConfig.TextColors[payload.kind] or NotificationConfig.TextColors[NotificationConfig.Kinds.Info]
	label.TextTransparency = 1
	label.Visible = true
end

local function reflow()
	for index, entry in ipairs(active) do
		if entry.label.Parent then
			entry.label.LayoutOrder = index
		end
	end
end

local function forget(entry)
	for index, current in ipairs(active) do
		if current == entry then
			table.remove(active, index)
			break
		end
	end
	reflow()
end

local function destroyEntry(entry, animate)
	if entry.removing then return end
	entry.removing = true
	forget(entry)

	local label = entry.label
	if not label.Parent then return end

	if not animate then
		label:Destroy()
		return
	end

	local tween = TweenService:Create(label, HIDE_TWEEN, { TextTransparency = 1 })
	tween.Completed:Connect(function()
		if label.Parent then
			label:Destroy()
		end
	end)
	tween:Play()
end

local function trimToMaxVisible()
	while #active > NotificationConfig.MaxVisible do
		destroyEntry(active[#active], false)
	end
end

function Notifications.show(payload)
	if not container or not template then return end

	local normalized = NotificationConfig.Normalize(payload)
	if not normalized then return end

	local label = template:Clone()
	label.Name = "Notification"
	applyItemStyle(label, normalized)
	label.Parent = container

	local entry = {
		label = label,
		removing = false,
	}

	table.insert(active, 1, entry)
	reflow()
	trimToMaxVisible()

	TweenService:Create(label, SHOW_TWEEN, { TextTransparency = 0 }):Play()

	task.delay(normalized.lifetime, function()
		destroyEntry(entry, true)
	end)
end

function Notifications.start()
	if started then return end
	started = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local hud = playerGui:WaitForChild(HUD_NAME, 10)
	if not hud then
		warn("[Notifications] Missing HUD ScreenGui")
		return
	end

	container = findContainer(hud)
	if not container then return end
	template = findItemTemplate(container)
	if not template then return end
	template.Visible = false
	if not ensureListLayout(container) then return end
	template.Parent = nil

	Remotes.get(Remotes.Names.PlayerNotification).OnClientEvent:Connect(Notifications.show)
end

return Notifications
