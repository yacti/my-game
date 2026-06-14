-- Renders the player's HUD from the Studio-authored template at
-- ReplicatedStorage.UI.HUD.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Onboarding = require(Shared:WaitForChild("Onboarding"))
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
	local hiddenDuringTutorial = hiddenDuringTutorialObjects(gui)

	local function setAmount(n)
		if label then label.Text = UiEffects.FormatCurrency(n) end
	end

	local function setTutorialVisibility(state)
		state = Onboarding.SanitizeState(state, Onboarding.CompleteState())
		local visible = not Onboarding.IsActive(state.Stage)
		for _, object in ipairs(hiddenDuringTutorial) do
			object.Visible = visible
		end
	end

	setAmount(PlayerStateStore.Get(PlayerStateStore.Fields.Currency) or 0)
	PlayerStateStore.Observe(PlayerStateStore.Fields.Currency, setAmount)
	setTutorialVisibility(PlayerStateStore.Get(PlayerStateStore.Fields.Onboarding))
	PlayerStateStore.Observe(PlayerStateStore.Fields.Onboarding, setTutorialVisibility)
end

return HudController
