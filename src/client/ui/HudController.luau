-- Renders the player's HUD from the Studio-authored template at
-- ReplicatedStorage.UI.HUD.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local HudController = {}

local function findCurrencyLabel(gui)
	local currency = gui:FindFirstChild("Currency")
	local amount = currency and currency:FindFirstChild("Amount")
	if amount and amount:IsA("TextLabel") then return amount end
	local named = gui:FindFirstChild("CurrencyLabel", true)
	if named and named:IsA("TextLabel") then return named end
	warn("[HudController] HUD missing Currency.Amount or CurrencyLabel TextLabel")
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

	local label = findCurrencyLabel(gui)

	local function setAmount(n)
		if label then label.Text = "$" .. math.floor(n or 0) end
	end

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.CurrencyUpdated).OnClientEvent, "HudController.SetAmount", setAmount)
end

return HudController
