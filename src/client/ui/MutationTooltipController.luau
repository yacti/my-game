-- Pointer tooltip for mutated world crops: hovering (desktop) or tapping
-- (mobile) a mutated patch crop or tree fruit pile shows its mutation names
-- ("Alien + Lightning"). Picking is screen-space projection over the crops
-- MutationVisuals already tracks, because crop geometry is CanQuery = false
-- and cannot be raycast.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Mutations = require(Shared:WaitForChild("Mutations"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local FeedPlacement = require(script.Parent:WaitForChild("FeedPlacement"))
local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local MutationVisuals = require(script.Parent:WaitForChild("MutationVisuals"))
local PlacementInput = require(script.Parent:WaitForChild("PlacementInput"))

local MutationTooltipController = {}

local LABEL_NAME = "__MutationTooltip"
local FONT_FACE = Font.new("rbxasset://fonts/families/ComicNeueAngular.json", Enum.FontWeight.Bold)
local TEXT_SIZE = 20
local LABEL_Z_INDEX = 9998
local POINTER_OFFSET = Vector2.new(10, 12)
local HOVER_REFRESH_SECONDS = 0.1
local TOUCH_DISMISS_SECONDS = 3
local MIN_PICK_RADIUS_PX = 18
local MAX_PICK_RADIUS_PX = 90
local GRADIENT_CYCLE_SECONDS = 2
local DEFAULT_TEXT_COLOR = Color3.new(1, 1, 1)

local player = Players.LocalPlayer
local label = nil
local touchShow = nil
local shownColors = nil

local function ensureLabel()
	if label and label.Parent then
		return label
	end

	local menu = MenuGui.Get("MutationTooltip")
	if not menu then
		return nil
	end

	local existing = menu:FindFirstChild(LABEL_NAME)
	if existing and existing:IsA("TextLabel") then
		label = existing
		return label
	end

	label = Instance.new("TextLabel")
	label.Name = LABEL_NAME
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.BackgroundTransparency = 1
	label.FontFace = FONT_FACE
	label.TextSize = TEXT_SIZE
	label.TextColor3 = Color3.new(1, 1, 1)
	label.ZIndex = LABEL_Z_INDEX
	label.Visible = false
	label.Selectable = false
	label.Active = false

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.new(0, 0, 0)
	-- Fixed-TextSize tooltip: the text never scales with the viewport, so the
	-- stroke must stay FixedSize too.
	stroke:SetAttribute("ResponsiveUiIgnore", true)
	stroke.Parent = label

	label.Parent = menu
	return label
end

local function menuGuiInset(menu)
	if menu:IsA("ScreenGui") and menu.IgnoreGuiInset then
		return Vector2.zero
	end
	local topLeftInset = GuiService:GetGuiInset()
	return Vector2.new(topLeftInset.X, topLeftInset.Y)
end

local function positionLabel(viewportPoint)
	local frame = ensureLabel()
	local menu = frame and frame.Parent
	if not (frame and menu) then
		return
	end

	local point = viewportPoint - menuGuiInset(menu) + POINTER_OFFSET
	local bounds = menu.AbsoluteSize
	local size = frame.AbsoluteSize
	frame.Position = UDim2.fromOffset(
		math.floor(math.clamp(point.X, 0, math.max(bounds.X - size.X, 0))),
		math.floor(math.clamp(point.Y, 0, math.max(bounds.Y - size.Y, 0)))
	)
end

local function hideLabel()
	if label then
		label.Visible = false
	end
	touchShow = nil
	shownColors = nil
end

-- Matches the forcefield overlay: static mutation color for singles, and the
-- same os.clock()-phased gradient cycle for stacks so text and overlay stay in sync.
local function refreshLabelColor()
	if not (label and label.Visible and shownColors) then
		return
	end
	local count = #shownColors
	if count == 1 then
		label.TextColor3 = shownColors[1]
		return
	end
	local phase = os.clock() / GRADIENT_CYCLE_SECONDS
	local fromIndex = math.floor(phase) % count + 1
	local toIndex = fromIndex % count + 1
	local alpha = phase % 1
	alpha = alpha * alpha * (3 - 2 * alpha)
	label.TextColor3 = shownColors[fromIndex]:Lerp(shownColors[toIndex], alpha)
end

local function showLabel(entry, viewportPoint)
	local frame = ensureLabel()
	if not frame then
		return
	end
	frame.Text = Mutations.DisplayNames(entry.mutationIds)
	shownColors = {}
	for index, mutationId in ipairs(entry.mutationIds) do
		shownColors[index] = Mutations.DisplayColor(mutationId) or DEFAULT_TEXT_COLOR
	end
	frame.Visible = true
	refreshLabelColor()
	positionLabel(viewportPoint)
end

local function pickAt(viewportPoint)
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end

	local halfViewportY = camera.ViewportSize.Y * 0.5
	local halfFovTan = math.tan(math.rad(camera.FieldOfView) * 0.5)
	if halfFovTan <= 0 then
		return nil
	end

	local best = nil
	local bestDistance = nil
	for _, entry in ipairs(MutationVisuals.VisibleMutatedCrops()) do
		local part = entry.part
		if part.Parent then
			local projected, onScreen = camera:WorldToViewportPoint(part.Position)
			if onScreen and projected.Z > 0 then
				local extent = math.max(part.Size.X, part.Size.Y, part.Size.Z)
				local radius = math.clamp(
					(extent * 0.5) / (projected.Z * halfFovTan) * halfViewportY,
					MIN_PICK_RADIUS_PX,
					MAX_PICK_RADIUS_PX
				)
				local distance = (Vector2.new(projected.X, projected.Y) - viewportPoint).Magnitude
				if distance <= radius and (bestDistance == nil or distance < bestDistance) then
					best = entry
					bestDistance = distance
				end
			end
		end
	end
	return best
end

local function isBlocked(screenPoint)
	if FeedPlacement.IsPlacementActive() or player:GetAttribute("EditMode") == true then
		return true
	end
	if UserInputService:GetFocusedTextBox() ~= nil then
		return true
	end
	return PlacementInput.IsInteractiveGuiAt(screenPoint)
end

local function touchShowExpired()
	if not touchShow then
		return false
	end
	if os.clock() >= touchShow.dismissAt then
		return true
	end
	local target = touchShow.target
	return not target:IsDescendantOf(Workspace) or #Mutations.FromInstance(target) == 0
end

local function stepHover(dt, state)
	refreshLabelColor()

	if touchShow then
		if touchShowExpired() then
			hideLabel()
		end
		return
	end

	if not UserInputService.MouseEnabled then
		return
	end

	local mouse = UserInputService:GetMouseLocation()
	state.elapsed += dt
	if state.elapsed < HOVER_REFRESH_SECONDS then
		if label and label.Visible then
			positionLabel(mouse)
		end
		return
	end
	state.elapsed = 0

	if isBlocked(mouse) then
		hideLabel()
		return
	end

	local entry = pickAt(mouse)
	if entry then
		showLabel(entry, mouse)
	else
		hideLabel()
	end
end

local function onTouchBegan(input, gameProcessed)
	if input.UserInputType ~= Enum.UserInputType.Touch or gameProcessed then
		return
	end

	local screenPoint = Vector2.new(input.Position.X, input.Position.Y)
	if isBlocked(screenPoint) then
		return
	end

	local topLeftInset = GuiService:GetGuiInset()
	local entry = pickAt(screenPoint + Vector2.new(topLeftInset.X, topLeftInset.Y))
	if entry then
		showLabel(entry, screenPoint + Vector2.new(topLeftInset.X, topLeftInset.Y))
		touchShow = {
			target = entry.target,
			dismissAt = os.clock() + TOUCH_DISMISS_SECONDS,
		}
	else
		hideLabel()
	end
end

function MutationTooltipController.start()
	local hoverState = { elapsed = 0 }
	RuntimeGuard.Connect(RunService.RenderStepped, "MutationTooltipController.Hover", function(dt)
		RuntimeGuard.Run("MutationTooltipController.StepHover", stepHover, dt, hoverState)
	end)
	RuntimeGuard.Connect(UserInputService.InputBegan, "MutationTooltipController.InputBegan", function(input, gameProcessed)
		RuntimeGuard.Run("MutationTooltipController.TouchBegan", onTouchBegan, input, gameProcessed)
	end)
end

return MutationTooltipController
