-- Renders the player's HUD (currency, later: inventory, etc).
-- Prefers a ScreenGui template at ReplicatedStorage.UI.HUD so the UI can be
-- edited visually in Roblox Studio. Falls back to a code-built HUD if no
-- template is present, so the game is never "UI-less".

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local HudController = {}

local function findCurrencyLabel(gui)
	local currency = gui:FindFirstChild("Currency")
	local amount = currency and currency:FindFirstChild("Amount")
	if amount and amount:IsA("TextLabel") then return amount end
	-- Fallback: any descendant TextLabel named "CurrencyLabel".
	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("TextLabel") and d.Name == "CurrencyLabel" then return d end
	end
	return nil
end

local function cloneTemplate()
	local uiFolder = ReplicatedStorage:FindFirstChild("UI")
	local template = uiFolder and uiFolder:FindFirstChild("HUD")
	if template and template:IsA("ScreenGui") then return template:Clone() end
	return nil
end

local function buildFallback()
	local gui = Instance.new("ScreenGui")
	gui.Name         = "HUD"
	gui.ResetOnSpawn = false

	local frame = Instance.new("Frame")
	frame.Name                 = "Currency"
	frame.Size                 = UDim2.new(0, 160, 0, 44)
	frame.Position             = UDim2.new(1, -176, 0, 16)
	frame.BackgroundColor3     = Color3.fromRGB(30, 30, 36)
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel      = 0
	frame.Parent               = gui
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

	local label = Instance.new("TextLabel")
	label.Name                 = "Amount"
	label.Size                 = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font                 = Enum.Font.GothamBold
	label.TextScaled           = true
	label.TextColor3           = Color3.fromRGB(255, 215, 90)
	label.Text                 = "$0"
	label.Parent               = frame

	return gui
end

function HudController.start()
	local player    = Players.LocalPlayer
	local PlayerGui = player:WaitForChild("PlayerGui")

	local gui = cloneTemplate() or buildFallback()
	gui.Parent = PlayerGui

	local label = findCurrencyLabel(gui)

	local function setAmount(n)
		if label then label.Text = "$" .. math.floor(n or 0) end
	end

	Remotes.get(Remotes.Names.CurrencyUpdated).OnClientEvent:Connect(setAmount)
end

return HudController
