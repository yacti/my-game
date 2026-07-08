local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local RuntimeGuard = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RuntimeGuard"))
local ResponsiveUi = require(script.Parent:WaitForChild("ResponsiveUi"))

local MenuGui = {}

-- Central game rules for every panel hosted under PlayerGui.Menu:
-- controllers register panels here, then use OpenPanel/ClosePanel/TogglePanel
-- so camera, blur, HUD visibility, and one-menu-at-a-time behavior stay consistent.
local MENU_NAME = "Menu"
local TEMPLATE_WAIT_SECONDS = 10
local HUD_NAME = "HUD"
local BLUR_NAME = "MenuBackgroundBlur"
local MENU_INITIALIZED_ATTR = "MenuGuiInitialized"
local TARGET_BLUR_SIZE = 18
local CAMERA_ZOOM_FOV = 12
local MIN_CAMERA_FOV = 40
local OPEN_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BLUR_CLOSE_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local cachedGui = nil
local registeredPanels = {}
local panelGroups = {}
local activePanelName = nil
local effectsActive = false
local effectsToken = 0
local baseCameraFov = nil
local hudWasEnabled = nil
local createdBlur = nil
local blurBaseSize = nil

local function tween(instance, tweenInfo, props)
	local created = TweenService:Create(instance, tweenInfo, props)
	created:Play()
	return created
end

local function playerGui()
	local player = Players.LocalPlayer
	return player and player:FindFirstChild("PlayerGui") or nil
end

local function setHudHidden(hidden)
	local gui = playerGui()
	local hud = gui and gui:FindFirstChild(HUD_NAME)
	if not (hud and hud:IsA("ScreenGui")) then
		return
	end

	if hidden then
		if hudWasEnabled == nil then
			hudWasEnabled = hud.Enabled
		end
		hud.Enabled = false
	else
		hud.Enabled = hudWasEnabled ~= false
		hudWasEnabled = nil
	end
end

local function menuBlur()
	local blur = Lighting:FindFirstChild(BLUR_NAME)
	if blur and blur:IsA("BlurEffect") then
		return blur
	end

	blur = Instance.new("BlurEffect")
	blur.Name = BLUR_NAME
	blur.Size = 0
	blur.Parent = Lighting
	createdBlur = blur
	return blur
end

local function applyMenuEffects(active)
	if effectsActive == active then
		return
	end

	effectsActive = active
	effectsToken += 1
	local token = effectsToken
	local camera = Workspace.CurrentCamera
	local blur = menuBlur()

	if active then
		if camera then
			baseCameraFov = camera.FieldOfView
			tween(camera, OPEN_TWEEN, {
				FieldOfView = math.max(baseCameraFov - CAMERA_ZOOM_FOV, MIN_CAMERA_FOV),
			})
		end
		blurBaseSize = blur.Size
		blur.Enabled = true
		tween(blur, OPEN_TWEEN, {
			Size = TARGET_BLUR_SIZE,
		})
		setHudHidden(true)
	else
		if camera and baseCameraFov then
			tween(camera, CLOSE_TWEEN, {
				FieldOfView = baseCameraFov,
			})
		end
		baseCameraFov = nil
		setHudHidden(false)

		local targetBlurSize = blurBaseSize or 0
		blurBaseSize = nil
		local blurTween = tween(blur, BLUR_CLOSE_TWEEN, {
			Size = targetBlurSize,
		})
		RuntimeGuard.Connect(blurTween.Completed, "MenuGui.BlurCloseCompleted", function()
			if effectsToken ~= token or effectsActive then
				return
			end
			if createdBlur == blur then
				blur:Destroy()
				createdBlur = nil
			elseif blur.Parent and targetBlurSize <= 0 then
				blur.Enabled = false
			end
		end)
	end
end

local function initializeMenu(menu)
	if not (menu and menu:IsA("ScreenGui")) then
		return
	end
	ResponsiveUi.BindRoot(menu)
	if menu:GetAttribute(MENU_INITIALIZED_ATTR) == true then
		return
	end
	menu:SetAttribute(MENU_INITIALIZED_ATTR, true)

	for _, child in ipairs(menu:GetChildren()) do
		if child:IsA("GuiObject") then
			child.Visible = false
		end
	end
end

local function callPanelHandler(panelName, handlerName, ...)
	local registration = registeredPanels[panelName]
	local handler = registration and registration[handlerName]
	if type(handler) ~= "function" then
		return true
	end

	local ok, err = pcall(handler, ...)
	if not ok then
		warn(string.format("[MenuGui] %s handler failed for %s: %s", handlerName, tostring(panelName), tostring(err)))
		return false
	end
	return true
end

local function closeRegisteredPanel(panelName, switching)
	callPanelHandler(panelName, "close", switching == true)
end

function MenuGui.Get(debugName)
	debugName = tostring(debugName or "MenuGui")

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	if cachedGui and cachedGui.Parent == playerGui then
		initializeMenu(cachedGui)
		return cachedGui
	end

	local existing = playerGui:FindFirstChild(MENU_NAME)
	if existing then
		if existing:IsA("ScreenGui") then
			cachedGui = existing
			initializeMenu(existing)
			return existing
		end
		warn(string.format("[%s] PlayerGui.%s exists but is not a ScreenGui", debugName, MENU_NAME))
		return nil
	end

	local uiFolder = ReplicatedStorage:WaitForChild("UI", TEMPLATE_WAIT_SECONDS)
	if not uiFolder then
		warn(string.format("[%s] Missing ReplicatedStorage.UI; menu UI disabled", debugName))
		return nil
	end

	local template = uiFolder:WaitForChild(MENU_NAME, TEMPLATE_WAIT_SECONDS)
	if not (template and template:IsA("ScreenGui")) then
		warn(string.format("[%s] Missing ReplicatedStorage.UI.%s ScreenGui", debugName, MENU_NAME))
		return nil
	end

	local clone = template:Clone()
	initializeMenu(clone)
	clone.Parent = playerGui
	cachedGui = clone
	return clone
end

function MenuGui.RegisterPanel(panelName, handlers)
	if type(panelName) ~= "string" or panelName == "" then
		return
	end

	handlers = type(handlers) == "table" and handlers or {}
	local registration = {}
	for key, value in pairs(handlers) do
		registration[key] = value
	end

	if type(registration.open) ~= "function" then
		registration.open = function()
			local frame = MenuGui.GetFrame(panelName, "MenuGui")
			if frame then
				frame.Visible = true
			end
		end
	end
	if type(registration.close) ~= "function" then
		registration.close = function()
			local frame = MenuGui.GetFrame(panelName, "MenuGui")
			if frame then
				frame.Visible = false
			end
		end
	end

	registeredPanels[panelName] = registration
	panelGroups[panelName] = type(registration.group) == "string" and registration.group ~= "" and registration.group or nil
end

function MenuGui.OpenPanel(panelName)
	local registration = registeredPanels[panelName]
	if not registration then
		warn(string.format("[MenuGui] Cannot open unregistered menu panel %q", tostring(panelName)))
		return false
	end

	if activePanelName == panelName then
		callPanelHandler(panelName, "refresh")
		return true
	end

	if activePanelName then
		closeRegisteredPanel(activePanelName, true)
	end

	activePanelName = panelName
	-- Panels registered with effects = false (e.g. the admin panel, a utility
	-- overlay) open without blur/camera zoom/HUD hiding; switching from an
	-- effects panel to one without turns the effects off.
	applyMenuEffects(registration.effects ~= false)

	if not callPanelHandler(panelName, "open") then
		activePanelName = nil
		applyMenuEffects(false)
		return false
	end
	return true
end

function MenuGui.ClosePanel(panelName)
	if activePanelName ~= panelName then
		return false
	end

	activePanelName = nil
	closeRegisteredPanel(panelName, false)
	applyMenuEffects(false)
	return true
end

function MenuGui.TogglePanel(panelName)
	if activePanelName == panelName then
		return MenuGui.ClosePanel(panelName)
	end
	return MenuGui.OpenPanel(panelName)
end

function MenuGui.IsOpen(panelName)
	return activePanelName == panelName
end

function MenuGui.ActivePanel()
	return activePanelName
end

function MenuGui.PanelGroup(panelName)
	return panelGroups[panelName]
end

function MenuGui.ActivePanelGroup()
	return activePanelName and MenuGui.PanelGroup(activePanelName) or nil
end

function MenuGui.GetFrame(frameName, debugName)
	local menu = MenuGui.Get(debugName)
	if not menu then
		return nil
	end

	local frame = menu:FindFirstChild(frameName)
	if frame and frame:IsA("GuiObject") then
		return frame
	end

	warn(string.format("[%s] Missing PlayerGui.%s.%s GuiObject", tostring(debugName or "MenuGui"), MENU_NAME, tostring(frameName)))
	return nil
end

return MenuGui
