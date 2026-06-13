local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local RuntimeGuard = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RuntimeGuard"))

local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local RobuxShopController = {}

local HUD_NAME = "HUD"
local HUD_LEFT_BUTTONS_NAME = "LeftButtons"
local HUD_SHOP_BUTTON_NAME = "ShopButton"
local HUD_SHOP_ALERT_NAME = "Alert"
local PANEL_NAME = "RobuxShop"
local SHOP_MENU_GROUP = "Shop"
local SHOP_PART_NAME = "RobuxShop"
local SHOP_PART_WAIT_SECONDS = 10
local PROXIMITY_SECONDS = 0.1

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

local function findHudOpenButton(playerGui)
	local hud = playerGui:WaitForChild(HUD_NAME, 10)
	if not hud then
		warn("[RobuxShopController] Missing PlayerGui.HUD for shop open button")
		return nil
	end

	local leftButtons = hud:FindFirstChild(HUD_LEFT_BUTTONS_NAME)
	if not (leftButtons and leftButtons:IsA("GuiObject")) then
		warn("[RobuxShopController] Missing HUD.LeftButtons for shop open button")
		return nil
	end

	local button = leftButtons:FindFirstChild(HUD_SHOP_BUTTON_NAME)
	if button and button:IsA("GuiButton") then
		return button
	end
	warn("[RobuxShopController] Missing HUD.LeftButtons.ShopButton GuiButton")
	return nil
end

local function shopPart()
	local map = Workspace:WaitForChild("Map", SHOP_PART_WAIT_SECONDS)
	local shopParts = map and map:WaitForChild("ShopParts", SHOP_PART_WAIT_SECONDS)
	local part = shopParts and shopParts:WaitForChild(SHOP_PART_NAME, SHOP_PART_WAIT_SECONDS)
	return part and part:IsA("BasePart") and part or nil
end

local function rootPart(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root or nil
end

local function nearShop(player, part)
	local root = rootPart(player)
	if not (part and root) then
		return false
	end

	local localPosition = part.CFrame:PointToObjectSpace(root.Position)
	local half = part.Size * 0.5
	return math.abs(localPosition.X) <= half.X
		and math.abs(localPosition.Y) <= half.Y
		and math.abs(localPosition.Z) <= half.Z
end

function RobuxShopController.start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local panel = MenuGui.GetFrame(PANEL_NAME, "RobuxShopController")
	if not panel then
		return
	end

	local gui = panel:FindFirstAncestorOfClass("ScreenGui")
	local closeButton = findDescendant(panel, "CloseButton", "GuiButton")
	if not closeButton then
		warn("[RobuxShopController] RobuxShop UI is missing CloseButton GuiButton")
		panel.Visible = false
		return
	end

	UiEffects.BindAllButtons(panel)
	RuntimeGuard.Connect(panel.DescendantAdded, "RobuxShopController.DescendantAdded", function(descendant)
		if descendant:IsA("GuiButton") then
			UiEffects.BindButton(descendant)
		elseif descendant:IsA("GuiObject") then
			UiEffects.BindAllButtons(descendant)
		end
	end)

	local openButton = findHudOpenButton(playerGui)
	if openButton then
		UiEffects.BindButton(openButton)
	end
	local shopAlert = openButton and openButton:FindFirstChild(HUD_SHOP_ALERT_NAME)
	if shopAlert and shopAlert:IsA("GuiObject") then
		shopAlert.Visible = true
	end

	local panelState = UiEffects.PreparePanel(panel)
	local isOpen = false
	local hasOpenedShop = false
	local openedByProximity = false
	local manuallyClosed = false
	local wasNear = false
	local pendingOpenSource = nil
	local transitionToken = 0

	local function showPanel()
		local source = pendingOpenSource
		openedByProximity = source == "proximity"
		if not hasOpenedShop then
			hasOpenedShop = true
			if shopAlert and shopAlert.Parent then
				shopAlert.Visible = false
			end
		end
		if isOpen then
			return
		end
		isOpen = true
		transitionToken += 1
		UiEffects.PlayOpen(panel, panelState)
	end

	local function hidePanel(switching)
		if not isOpen and not panel.Visible then
			return
		end
		isOpen = false
		openedByProximity = false
		transitionToken += 1
		local token = transitionToken
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

	local function openFrom(source)
		pendingOpenSource = source
		local opened = MenuGui.OpenPanel(PANEL_NAME)
		pendingOpenSource = nil
		return opened
	end

	MenuGui.RegisterPanel(PANEL_NAME, {
		group = SHOP_MENU_GROUP,
		open = showPanel,
		close = hidePanel,
	})

	RuntimeGuard.Connect(closeButton.Activated, "RobuxShopController.CloseActivated", function()
		manuallyClosed = true
		MenuGui.ClosePanel(PANEL_NAME)
	end)

	if openButton then
		RuntimeGuard.Connect(openButton.Activated, "RobuxShopController.ToggleActivated", function()
			if MenuGui.IsOpen(PANEL_NAME) then
				manuallyClosed = true
				MenuGui.ClosePanel(PANEL_NAME)
				return
			end
			manuallyClosed = false
			openFrom("hud")
		end)
	end

	RuntimeGuard.Spawn("RobuxShopController.Proximity", function()
		local part = shopPart()
		if not part then
			warn("[RobuxShopController] Missing Workspace.Map.ShopParts.RobuxShop BasePart; proximity open disabled")
			return
		end

		while gui and gui.Parent do
			local near = nearShop(player, part)
			if near and not wasNear then
				manuallyClosed = false
			end

			if near then
				local activePanel = MenuGui.ActivePanel()
				if not manuallyClosed
					and not MenuGui.IsOpen(PANEL_NAME)
					and (activePanel == nil or activePanel == PANEL_NAME or MenuGui.ActivePanelGroup() == SHOP_MENU_GROUP) then
					openFrom("proximity")
				end
			else
				manuallyClosed = false
				if openedByProximity and MenuGui.IsOpen(PANEL_NAME) then
					MenuGui.ClosePanel(PANEL_NAME)
				end
			end

			wasNear = near
			task.wait(PROXIMITY_SECONDS)
		end
	end)
end

return RobuxShopController
