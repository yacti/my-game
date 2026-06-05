-- Renders the player's HUD from the Studio-authored template at
-- ReplicatedStorage.UI.HUD.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local HudController = {}
local LEFT_BUTTONS_NAME = "LeftButtons"

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

local function cloneTemplate()
	local uiFolder = ReplicatedStorage:FindFirstChild("UI")
	local template = uiFolder and uiFolder:FindFirstChild("HUD")
	if template and template:IsA("ScreenGui") then return template:Clone() end
	warn("[HudController] Missing ReplicatedStorage.UI.HUD ScreenGui")
	return nil
end

function HudController.start()
	local player    = Players.LocalPlayer
	local PlayerGui = player:WaitForChild("PlayerGui")

	local gui = cloneTemplate()
	if not gui then return end
	gui.Parent = PlayerGui

	local leftButtons = gui:FindFirstChild(LEFT_BUTTONS_NAME)
	if leftButtons and leftButtons:IsA("GuiObject") then
		UiEffects.BindAllButtons(leftButtons)
	else
		warn("[HudController] HUD missing LeftButtons GuiObject")
	end

	local label = findCurrencyLabel(gui)

	local function setAmount(n)
		if label then label.Text = "$" .. math.floor(n or 0) end
	end

	setAmount(PlayerStateStore.Get(PlayerStateStore.Fields.Currency) or 0)
	PlayerStateStore.Observe(PlayerStateStore.Fields.Currency, setAmount)
end

return HudController
