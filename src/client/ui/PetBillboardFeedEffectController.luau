local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local XPBillboardTemplate = require(script.Parent:WaitForChild("XPBillboardTemplate"))

local PetBillboardFeedEffectController = {}

local FLOAT_TWEEN = TweenInfo.new(1.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HEAD_START_OFFSET = Vector3.new(1.35, 0.25, 0)
local ROOT_START_OFFSET = Vector3.new(1.35, 2.5, 0)
local RISE_OFFSET = Vector3.new(0, 1.35, 0)
local STACK_OFFSET = Vector3.new(0, 0.18, 0)
local MAX_ACTIVE = 8
local MAX_DISTANCE = 80

local player = Players.LocalPlayer
local playerGui = nil
local activeBillboards = {}

local function removeBillboard(gui)
	for index, active in ipairs(activeBillboards) do
		if active == gui then
			table.remove(activeBillboards, index)
			break
		end
	end
	if gui and gui.Parent then
		gui:Destroy()
	end
end

local function trimActiveBillboards()
	while #activeBillboards >= MAX_ACTIVE do
		removeBillboard(activeBillboards[1])
	end
end

local function characterAdornee()
	local character = player.Character
	if not character then
		return nil, nil
	end

	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head, HEAD_START_OFFSET
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root, ROOT_START_OFFSET
	end

	return nil, nil
end

local function xpFromPayload(payload)
	if type(payload) == "table" then
		return tonumber(payload.xp)
	end
	return tonumber(payload)
end

local function ensureFixedTextStroke(label)
	local stroke = label:FindFirstChildOfClass("UIStroke")
	if not stroke then
		stroke = Instance.new("UIStroke")
		stroke.Name = "UIStroke"
		stroke.Parent = label
	end
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Color = label.TextStrokeColor3
	stroke.Thickness = 1
	stroke.Transparency = 0
	return stroke
end

local function tweenLabelFade(label)
	TweenService:Create(label, FLOAT_TWEEN, {
		BackgroundTransparency = 1,
		TextStrokeTransparency = 1,
		TextTransparency = 1,
	}):Play()

	for _, descendant in ipairs(label:GetDescendants()) do
		if descendant:IsA("UIStroke") then
			TweenService:Create(descendant, FLOAT_TWEEN, { Transparency = 1 }):Play()
		end
	end
end

local function play(payload)
	local xp = xpFromPayload(payload)
	if type(xp) ~= "number" or xp <= 0 then
		return
	end

	local adornee, baseOffset = characterAdornee()
	if not (adornee and playerGui) then
		return
	end

	local gui, label = XPBillboardTemplate.Clone("PetBillboardFeedEffectController")
	if not gui then
		return
	end

	trimActiveBillboards()

	local startOffset = baseOffset + STACK_OFFSET * #activeBillboards
	gui.Name = "PetBillboardFeedEffect"
	gui.Adornee = adornee
	gui.MaxDistance = MAX_DISTANCE
	gui.StudsOffset = startOffset
	label.BackgroundTransparency = 1
	label.TextTransparency = 0
	label.Text = "+" .. NumberFormatter.XP(xp)
	ensureFixedTextStroke(label)

	table.insert(activeBillboards, gui)
	gui.Parent = playerGui

	tweenLabelFade(label)
	local moveTween = TweenService:Create(gui, FLOAT_TWEEN, {
		StudsOffset = startOffset + RISE_OFFSET,
	})
	moveTween.Completed:Connect(function()
		removeBillboard(gui)
	end)
	moveTween:Play()

	task.delay(FLOAT_TWEEN.Time + 0.25, function()
		removeBillboard(gui)
	end)
end

function PetBillboardFeedEffectController.start()
	playerGui = player:WaitForChild("PlayerGui")
	RuntimeGuard.Connect(
		Remotes.get(Remotes.Names.PetBillboardFeedEffect).OnClientEvent,
		"PetBillboardFeedEffectController.Play",
		play
	)
end

return PetBillboardFeedEffectController
