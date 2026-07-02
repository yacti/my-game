-- While the Roblox in-experience (Esc) menu is open, reveal the authored
-- HUD.WorksOffline banner and hide every other piece of game UI, then animate
-- the banner's text with the Mythical rarity rainbow. Nothing here is
-- destructive: every ScreenGui we disable and every HUD widget we hide is
-- recorded and restored the moment the menu closes.
--
-- The banner lives *inside* the HUD ScreenGui, so we cannot hide the game UI
-- by disabling the HUD wholesale; instead we hide the HUD's sibling widgets and
-- keep the banner. Roblox core UI (topbar/chat/leaderboard) is left untouched.
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Rarities = require(Shared:WaitForChild("Rarities"))

local WorksOfflineController = {}

local HUD_NAME = "HUD"
local FRAME_NAME = "WorksOffline"
local LABEL_NAME = "WorksOffline"
local HUD_WAIT_SECONDS = 10
-- The shared Mythical rainbow cycles every ~4s; the banner runs it this many
-- times faster (kept local so other Mythical UI is unaffected).
local RAINBOW_SPEED = 3

local player = Players.LocalPlayer

local started = false
local menuActive = false
local hud = nil
local frame = nil
local label = nil
local hudEnabledBefore = nil
local hiddenScreenGuis = {}
local hiddenHudChildren = {}
local rainbowConnection = nil

local function resolveElements()
	if hud and hud.Parent and frame and frame.Parent and label and label.Parent then
		return true
	end
	local playerGui = player:WaitForChild("PlayerGui")
	local foundHud = playerGui:WaitForChild(HUD_NAME, HUD_WAIT_SECONDS)
	if not (foundHud and foundHud:IsA("ScreenGui")) then
		warn("[WorksOfflineController] Missing PlayerGui.HUD ScreenGui")
		return false
	end
	local foundFrame = foundHud:FindFirstChild(FRAME_NAME)
	if not (foundFrame and foundFrame:IsA("GuiObject")) then
		warn("[WorksOfflineController] Missing HUD.WorksOffline frame")
		return false
	end
	local foundLabel = foundFrame:FindFirstChild(LABEL_NAME)
	if not (foundLabel and foundLabel:IsA("TextLabel")) then
		warn("[WorksOfflineController] Missing HUD.WorksOffline.WorksOffline TextLabel")
		return false
	end
	hud, frame, label = foundHud, foundFrame, foundLabel
	return true
end

local function startRainbow()
	if rainbowConnection then
		return
	end
	rainbowConnection = RuntimeGuard.Connect(RunService.Heartbeat, "WorksOfflineController.Rainbow", function()
		if not (label and label.Parent) then
			return
		end
		-- Mythical is the game's only animated rarity, so ColorFor cycles the hue;
		-- scaling the clock cycles it faster than the shared 4s period.
		label.TextColor3 = Rarities.ColorFor(Rarities.Mythical, os.clock() * RAINBOW_SPEED)
	end)
end

local function stopRainbow()
	if rainbowConnection then
		rainbowConnection:Disconnect()
		rainbowConnection = nil
	end
end

local function showBanner()
	local playerGui = player:WaitForChild("PlayerGui")
	-- Disable every other game ScreenGui (Menu, shops, hotbar, custom topbar…).
	for _, gui in ipairs(playerGui:GetChildren()) do
		if gui ~= hud and gui:IsA("ScreenGui") and gui.Enabled then
			gui.Enabled = false
			table.insert(hiddenScreenGuis, gui)
		end
	end
	-- Hide the HUD's own widgets, keeping only the WorksOffline banner.
	for _, child in ipairs(hud:GetChildren()) do
		if child ~= frame and child:IsA("GuiObject") and child.Visible then
			child.Visible = false
			table.insert(hiddenHudChildren, child)
		end
	end
	hudEnabledBefore = hud.Enabled
	hud.Enabled = true
	frame.Visible = true
	startRainbow()
end

local function restoreBanner()
	stopRainbow()
	if frame and frame.Parent then
		frame.Visible = false
	end
	for _, child in ipairs(hiddenHudChildren) do
		if child.Parent then
			child.Visible = true
		end
	end
	table.clear(hiddenHudChildren)
	for _, gui in ipairs(hiddenScreenGuis) do
		if gui.Parent then
			gui.Enabled = true
		end
	end
	table.clear(hiddenScreenGuis)
	if hud and hud.Parent and hudEnabledBefore ~= nil then
		hud.Enabled = hudEnabledBefore
	end
	hudEnabledBefore = nil
end

local function onMenuOpened()
	if menuActive then
		return
	end
	if not resolveElements() then
		return
	end
	menuActive = true
	showBanner()
end

local function onMenuClosed()
	if not menuActive then
		return
	end
	menuActive = false
	restoreBanner()
end

function WorksOfflineController.start()
	if started then
		return
	end
	started = true
	RuntimeGuard.Connect(GuiService.MenuOpened, "WorksOfflineController.MenuOpened", onMenuOpened)
	RuntimeGuard.Connect(GuiService.MenuClosed, "WorksOfflineController.MenuClosed", onMenuClosed)
end

return WorksOfflineController
