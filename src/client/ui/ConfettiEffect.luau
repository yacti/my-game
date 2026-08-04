-- Screen-space confetti bursts (ported from the Studio-authored ConfettiHandler
-- module). Visual behavior is preserved from the original; the implementation
-- follows the rulebook instead of the original's shape: all pieces simulate
-- under ONE shared RenderStepped connection (not one per piece), the ScreenGui
-- is created lazily once, and the replicated celebration sound is cloned and
-- reused across bursts without busy-waiting on load.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))

local ConfettiEffect = {}

local DEFAULT_AMOUNT = 250
local MAX_ACTIVE_PIECES = 600
-- Above the Menu ScreenGui (DisplayOrder 0) and the topbar (10/11) so bursts
-- fall over open panels instead of behind them, but below the notification
-- overlay (50) so toasts stay readable through the confetti.
local DISPLAY_ORDER = 25
local GRAVITY = 75
local FALL_LIMIT = 1.3
local FADE_IN_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Quart, Enum.EasingDirection.InOut)

local CONFETTI_SHAPES = { "Square", "Circle", "Triangle", "Diamond" }
local BASE_COLORS = {
	Color3.fromRGB(255, 75, 75),
	Color3.fromRGB(75, 255, 75),
	Color3.fromRGB(75, 75, 255),
	Color3.fromRGB(255, 255, 75),
	Color3.fromRGB(255, 75, 255),
	Color3.fromRGB(75, 255, 255),
}

local player = Players.LocalPlayer

local screenGui = nil
local pieces = {} -- [frame] = { velocityX, velocityY, rotationSpeed, startClock }
local pieceCount = 0
local stepConnection = nil

local function ensureGui()
	if screenGui and screenGui.Parent then
		return screenGui
	end
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ConfettiGui"
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = DISPLAY_ORDER
	screenGui.Parent = playerGui
	return screenGui
end

local function playSound()
	SoundEffects.Play(SoundEffects.Names.Confetti)
end

local function createPiece(spawnPos)
	local confetti = Instance.new("Frame")
	confetti.Name = "ConfettiPiece"
	local size = math.random(24, 36)
	confetti.Size = UDim2.new(0, size, 0, size)
	confetti.BackgroundTransparency = 1
	confetti.BorderSizePixel = 0
	confetti.AnchorPoint = Vector2.new(0.5, 0.5)

	if spawnPos and typeof(spawnPos) == "UDim2" then
		confetti.Position = spawnPos
	else
		confetti.Position = UDim2.fromScale(math.random(0, 100) / 100, math.random(-25, 125) / 100)
	end

	local baseColor = BASE_COLORS[math.random(#BASE_COLORS)]
	local brightnessFactor = math.random(95, 105) / 100
	confetti.BackgroundColor3 = Color3.new(
		math.clamp(baseColor.R * brightnessFactor, 0, 1),
		math.clamp(baseColor.G * brightnessFactor, 0, 1),
		math.clamp(baseColor.B * brightnessFactor, 0, 1)
	)

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = math.random(0, 360)
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(math.random(75, 100) / 100, math.random(75, 100) / 100, math.random(75, 100) / 100)),
		ColorSequenceKeypoint.new(1, Color3.new(math.random(75, 100) / 100, math.random(75, 100) / 100, math.random(75, 100) / 100)),
	})
	gradient.Parent = confetti

	local shapeType = CONFETTI_SHAPES[math.random(#CONFETTI_SHAPES)]
	local uiCorner = Instance.new("UICorner")
	if shapeType == "Circle" then
		uiCorner.CornerRadius = UDim.new(1, 0)
	elseif shapeType == "Diamond" then
		confetti.Rotation = 45
	elseif shapeType == "Triangle" then
		confetti.Size = UDim2.new(0, math.random(28, 38), 0, math.random(18, 28))
	end
	uiCorner.Parent = confetti

	TweenService:Create(confetti, FADE_IN_TWEEN, { BackgroundTransparency = 0 }):Play()
	return confetti
end

local function removePiece(confetti)
	if pieces[confetti] == nil then
		return
	end
	pieces[confetti] = nil
	pieceCount -= 1
	confetti:Destroy()
end

local function step(deltaTime)
	local now = os.clock()
	for confetti, state in pairs(pieces) do
		if not confetti.Parent then
			removePiece(confetti)
		else
			local elapsed = now - state.startClock
			local newX = confetti.Position.X.Scale + (state.velocityX * deltaTime / 400)
			local newY = confetti.Position.Y.Scale
				+ (state.velocityY * deltaTime / 400)
				+ (0.5 * GRAVITY * elapsed ^ 2 / 3000)
			confetti.Position = UDim2.new(newX, 0, math.min(newY, FALL_LIMIT), 0)
			confetti.Rotation += state.rotationSpeed * deltaTime + math.sin(elapsed * 2) * 0.5

			if newY > FALL_LIMIT then
				removePiece(confetti)
			end
		end
	end

	if pieceCount <= 0 and stepConnection then
		stepConnection:Disconnect()
		stepConnection = nil
	end
end

local function ensureStepper()
	if stepConnection then
		return
	end
	stepConnection = RuntimeGuard.Connect(RunService.RenderStepped, "ConfettiEffect.Step", step)
end

function ConfettiEffect.Emit(amount, spawnPos)
	if type(amount) ~= "number" then
		amount = DEFAULT_AMOUNT
	end

	local gui = ensureGui()
	if not gui then
		return
	end
	playSound()

	amount = math.min(amount, math.max(MAX_ACTIVE_PIECES - pieceCount, 0))
	local startClock = os.clock()
	for _ = 1, amount do
		local confetti = createPiece(spawnPos)
		confetti.Parent = gui
		pieces[confetti] = {
			velocityX = math.random(-300, 300),
			velocityY = math.random(-350, -200),
			rotationSpeed = math.random(-300, 300),
			startClock = startClock,
		}
		pieceCount += 1
	end
	if pieceCount > 0 then
		ensureStepper()
	end
end

return ConfettiEffect
