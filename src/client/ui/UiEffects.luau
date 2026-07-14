-- Shared UI polish helpers, and the single owner of the world-billboard
-- lifecycle. Every in-world BillboardGui in the game follows one pattern:
--
--   1. clone a Studio template from ReplicatedStorage.UI.BillboardGUIs
--   2. set content (Text/colors) on the clone — never on the template
--   3. UiEffects.BindBillboardPop(clone), then set Adornee and Parent
--   4. optionally UiEffects.BindBillboardDistancePop(clone) for range gating
--
-- After binding, `Enabled` is the only external visibility API; UiEffects owns
-- `Size` (pop/hide animations, distance parking) and `MaxDistance` (replaced
-- by a managed sentinel; the authored value is kept in the
-- UiEffectsBaseMaxDistance attribute). Do not write billboard Size directly
-- after binding, and never size any world gui to zero — growing a TextLabel
-- from zero size permanently breaks its glyph layout under a live engine bug
-- (see BILLBOARD_HIDDEN_SCALE below). Hidden billboards park at a tiny
-- non-zero size and are additionally hidden from the local player via
-- PlayerToHideFrom while parked (Enabled stays untouched as the external
-- desired-visibility input), and every completed pop runs a text-layout heal
-- that rewrites any label whose TextBounds got stuck at 0/NaN.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))

local UiEffects = {}

local BUTTON_EFFECTS_ATTR = "UiEffectsButtonBound"
local BILLBOARD_POP_ATTR = "UiEffectsBillboardPopBound"
-- Authored size/MaxDistance stored on the billboard itself: attributes travel
-- with clones and survive lost bookkeeping, so a billboard can always be
-- restored to its true size instead of adopting a mid-animation one.
local BILLBOARD_BASE_SIZE_ATTR = "UiEffectsBaseSize"
local BILLBOARD_BASE_MAX_DISTANCE_ATTR = "UiEffectsBaseMaxDistance"
local GENERATED_SCALE_ATTR = "UiEffectsGeneratedScale"

local OPEN_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BILLBOARD_POP_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local BILLBOARD_HIDE_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local BILLBOARD_POP_START_SCALE = 0.18
-- Hidden billboards park at a tiny non-zero size, never zero: growing a
-- TextLabel from zero size can permanently break its glyph layout (TextBounds
-- sticks at 0/NaN and the text stops drawing while sibling frames render) —
-- live engine regression as of July 2026, confirmed in-place with a 60-board
-- park/grow rig: https://devforum.roblox.com/t/4714195. Parked billboards are
-- also hidden via PlayerToHideFrom so nothing renders; the non-zero park size
-- exists purely so the next grow never starts from zero.
local BILLBOARD_HIDDEN_SCALE = 0.02
local BILLBOARD_TEXT_HEAL_DELAY = 0.1
local BILLBOARD_MANAGED_MAX_DISTANCE = 100000
local BILLBOARD_DISTANCE_CHECK_INTERVAL = 0.15
local GROUP_FADE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function darken(color, amount)
	return Color3.new(
		math.clamp(color.R * amount, 0, 1),
		math.clamp(color.G * amount, 0, 1),
		math.clamp(color.B * amount, 0, 1)
	)
end

local function scaleUDim2(value, scale)
	return UDim2.new(
		value.X.Scale * scale,
		math.floor(value.X.Offset * scale),
		value.Y.Scale * scale,
		math.floor(value.Y.Offset * scale)
	)
end

local function findScale(guiObject)
	return guiObject:FindFirstChildOfClass("UIScale")
end

local function ensureScale(guiObject)
	local scale = findScale(guiObject)
	if scale then
		return scale
	end
	scale = Instance.new("UIScale")
	scale.Name = "UiEffectsScale"
	scale:SetAttribute(GENERATED_SCALE_ATTR, true)
	scale.Parent = guiObject
	return scale
end

local function tween(instance, tweenInfo, props)
	local created = TweenService:Create(instance, tweenInfo, props)
	created:Play()
	return created
end

local function buttonColorTarget(button)
	if button:IsA("ImageButton") then
		return "ImageColor3", button.ImageColor3
	end
	return "BackgroundColor3", button.BackgroundColor3
end

local pressedButtons = setmetatable({}, { __mode = "k" })
local billboardBaseSizes = setmetatable({}, { __mode = "k" })
local billboardPopTokens = setmetatable({}, { __mode = "k" })
local distanceBillboards = setmetatable({}, { __mode = "k" })
-- Bound-state lives here rather than in the BILLBOARD_POP_ATTR attribute:
-- attributes are copied by Clone(), so a clone of a bound billboard would
-- otherwise look bound while having none of the per-instance state.
local boundPopBillboards = setmetatable({}, { __mode = "k" })
local inputEndedConnection = nil
local billboardDistanceConnection = nil

local function isDegenerateSize(size)
	return size.X.Scale == 0 and size.X.Offset == 0 and size.Y.Scale == 0 and size.Y.Offset == 0
end

local function billboardBaseSize(billboard)
	local cached = billboardBaseSizes[billboard]
	if cached then
		return cached
	end
	local stored = billboard:GetAttribute(BILLBOARD_BASE_SIZE_ATTR)
	local base = typeof(stored) == "UDim2" and stored or billboard.Size
	if isDegenerateSize(base) then
		-- Never adopt a zeroed size as the authored size (e.g. a clone taken
		-- while its source was distance-hidden): leave it uncached so a later
		-- honest size can win.
		return base
	end
	billboardBaseSizes[billboard] = base
	if typeof(stored) ~= "UDim2" then
		billboard:SetAttribute(BILLBOARD_BASE_SIZE_ATTR, base)
	end
	return base
end

local function ensureInputEndedConnection()
	if inputEndedConnection then
		return
	end

	inputEndedConnection = RuntimeGuard.Connect(UserInputService.InputEnded, "UiEffects.InputEnded", function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		for _, release in pairs(pressedButtons) do
			release()
		end
	end)
end

function UiEffects.BindButton(button, options)
	if not (button and button:IsA("GuiButton")) then
		return
	end
	if button:GetAttribute(BUTTON_EFFECTS_ATTR) == true then
		return
	end
	options = type(options) == "table" and options or {}
	button:SetAttribute(BUTTON_EFFECTS_ATTR, true)

	local colorProp, baseColor = buttonColorTarget(button)
	local hoverColor = darken(baseColor, 0.72)
	local useColorTween = options.colorTween ~= false
	-- pressScale=false skips the press-shrink UIScale. Required for world-gui
	-- (SurfaceGui) buttons: moving the button under the cursor mid-press makes
	-- the engine release over a different element, so Activated never fires.
	local uiScale = options.pressScale ~= false and ensureScale(button) or nil
	local baseScale = uiScale and uiScale.Scale or 1
	local hovering = false
	local pressing = false

	ensureInputEndedConnection()

	local function setHover(active)
		if button.Active == false then
			active = false
		end
		hovering = active
		if useColorTween then
			tween(button, HOVER_TWEEN, {
				[colorProp] = active and hoverColor or baseColor,
			})
		end
	end

	local function setPressed(active)
		if button.Active == false then
			active = false
		end
		pressing = active
		if uiScale then
			tween(uiScale, PRESS_TWEEN, {
				Scale = active and baseScale * 0.92 or baseScale,
			})
		end
	end

	local function releasePress()
		if not pressing then
			return
		end
		pressedButtons[button] = nil
		setPressed(false)
		if not hovering then
			setHover(false)
		end
	end

	RuntimeGuard.Connect(button.MouseEnter, "UiEffects.MouseEnter", function()
		setHover(true)
	end)

	RuntimeGuard.Connect(button.MouseLeave, "UiEffects.MouseLeave", function()
		setHover(false)
		releasePress()
	end)

	RuntimeGuard.Connect(button.MouseButton1Down, "UiEffects.MouseButton1Down", function()
		setPressed(true)
		if pressing then
			pressedButtons[button] = releasePress
		end
	end)

	RuntimeGuard.Connect(button.MouseButton1Up, "UiEffects.MouseButton1Up", function()
		releasePress()
	end)

	RuntimeGuard.Connect(button.Activated, "UiEffects.Activated", function()
		if button.Active == false then
			return
		end
		if options.silent ~= true then
			SoundEffects.Play(SoundEffects.Names.UiButtonClick)
		end
	end)

	RuntimeGuard.Connect(button.Destroying, "UiEffects.ButtonDestroying", function()
		pressedButtons[button] = nil
	end)
end

function UiEffects.BindAllButtons(root)
	if not root then
		return
	end
	if root:IsA("GuiButton") then
		UiEffects.BindButton(root)
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("GuiButton") then
			UiEffects.BindButton(descendant)
		end
	end
end

-- Workaround for the July 2026 zero-size text-layout engine bug (see
-- BILLBOARD_HIDDEN_SCALE): a label that grew through a degenerate size keeps
-- TextBounds at 0/NaN and never draws its glyphs again until the text is
-- rewritten. After every pop lands, rewrite the text of any label stuck in
-- that state. Labels that are legitimately tiny, hidden, faded, or empty are
-- skipped, and the rewrite is invisible (same string back in the same frame).
local function healBillboardTextLayout(billboard)
	if not billboard.Parent or not billboard.Enabled then
		return
	end
	for _, descendant in ipairs(billboard:GetDescendants()) do
		if (descendant:IsA("TextLabel") or descendant:IsA("TextButton"))
			and descendant.Visible
			and descendant.Text ~= ""
			and descendant.TextTransparency < 0.99
			and descendant.AbsoluteSize.Y >= 2 then
			local bounds = descendant.TextBounds
			if bounds.X ~= bounds.X or bounds.Y ~= bounds.Y or bounds.X <= 0 or bounds.Y <= 0 then
				local text = descendant.Text
				descendant.Text = ""
				descendant.Text = text
			end
		end
	end
end

function UiEffects.PlayBillboardPop(billboard)
	if not (billboard and billboard:IsA("BillboardGui")) then
		return nil
	end
	local distanceRecord = distanceBillboards[billboard]
	if distanceRecord and distanceRecord.allowPop ~= true then
		return nil
	end

	local baseSize = billboardBaseSize(billboard)

	local token = (billboardPopTokens[billboard] or 0) + 1
	billboardPopTokens[billboard] = token

	billboard.Size = scaleUDim2(baseSize, BILLBOARD_POP_START_SCALE)
	local popTween = tween(billboard, BILLBOARD_POP_TWEEN, {
		Size = baseSize,
	})
	RuntimeGuard.Connect(popTween.Completed, "UiEffects.BillboardPopCompleted", function(playbackState)
		if billboardPopTokens[billboard] ~= token then
			return
		end
		if billboard.Parent then
			billboard.Size = baseSize
		end
		if playbackState == Enum.PlaybackState.Completed then
			task.delay(BILLBOARD_TEXT_HEAL_DELAY, function()
				if billboardPopTokens[billboard] == token then
					RuntimeGuard.Run("UiEffects.HealBillboardTextLayout", healBillboardTextLayout, billboard)
				end
			end)
		end
	end)
	return popTween
end

function UiEffects.BindBillboardPop(billboard)
	if not (billboard and billboard:IsA("BillboardGui")) then
		return
	end
	if boundPopBillboards[billboard] then
		return
	end
	if billboard:GetAttribute(BILLBOARD_POP_ATTR) == true then
		-- Clone of a bound billboard: the attribute travelled with Clone()
		-- but none of the per-instance state did. Restore the authored size
		-- (the clone may have been taken mid-pop or while hidden) and rebind.
		local stored = billboard:GetAttribute(BILLBOARD_BASE_SIZE_ATTR)
		if typeof(stored) == "UDim2" and not isDegenerateSize(stored) then
			billboard.Size = stored
		end
	end
	boundPopBillboards[billboard] = true
	billboard:SetAttribute(BILLBOARD_POP_ATTR, true)

	RuntimeGuard.Connect(billboard:GetPropertyChangedSignal("Enabled"), "UiEffects.BillboardEnabled", function()
		if billboard.Enabled then
			UiEffects.PlayBillboardPop(billboard)
		end
	end)
	RuntimeGuard.Connect(billboard.Destroying, "UiEffects.BillboardDestroying", function()
		billboardBaseSizes[billboard] = nil
		billboardPopTokens[billboard] = nil
	end)

	if billboard.Enabled then
		task.defer(function()
			if billboard.Parent and billboard.Enabled then
				UiEffects.PlayBillboardPop(billboard)
			end
		end)
	end
end

local function nextBillboardToken(billboard)
	local token = (billboardPopTokens[billboard] or 0) + 1
	billboardPopTokens[billboard] = token
	return token
end

local function billboardWorldPosition(billboard)
	local target = billboard.Adornee or billboard.Parent
	if not target then
		return nil
	end
	if target:IsA("Attachment") then
		return target.WorldPosition
	end
	if target:IsA("BasePart") then
		return target.Position
	end
	if target:IsA("Model") then
		return target:GetPivot().Position
	end
	return nil
end

local function distanceBillboardInRange(billboard, record)
	local camera = Workspace.CurrentCamera
	local position = camera and billboardWorldPosition(billboard)
	if not position then
		return true
	end
	return (camera.CFrame.Position - position).Magnitude <= record.maxDistance
end

local function distanceBillboardShouldShow(billboard, record)
	return record.desiredEnabled == true and distanceBillboardInRange(billboard, record)
end

-- Parked billboards are hidden via PlayerToHideFrom so the tiny non-zero park
-- size can never show as a speck. Deliberately NOT Enabled: that property is
-- the external desired-visibility input, and with deferred signal behavior a
-- gate-owned write there is indistinguishable from a controller's by the time
-- the property signal delivers. PlayerToHideFrom is unused by the rest of the
-- game, is client-local here, and fully stops the billboard rendering.
local function setGateHidden(billboard, hidden)
	billboard.PlayerToHideFrom = hidden and Players.LocalPlayer or nil
end

local function playBillboardHide(billboard, record)
	local baseSize = billboardBaseSize(billboard)
	local token = nextBillboardToken(billboard)
	record.visible = false
	record.closing = true

	local hideTween = tween(billboard, BILLBOARD_HIDE_TWEEN, {
		Size = scaleUDim2(baseSize, BILLBOARD_POP_START_SCALE),
	})
	RuntimeGuard.Connect(hideTween.Completed, "UiEffects.BillboardHideCompleted", function()
		if billboardPopTokens[billboard] ~= token then
			return
		end
		record.closing = false
		if billboard.Parent and not distanceBillboardShouldShow(billboard, record) then
			billboard.Size = scaleUDim2(baseSize, BILLBOARD_HIDDEN_SCALE)
			setGateHidden(billboard, true)
		end
	end)
end

local function updateDistanceBillboard(billboard)
	local record = distanceBillboards[billboard]
	if not record then
		return
	end

	if record.desiredEnabled ~= true then
		record.visible = false
		record.closing = false
		billboard.Size = billboardBaseSize(billboard)
		setGateHidden(billboard, false)
		return
	end

	if distanceBillboardShouldShow(billboard, record) then
		if record.visible == true and billboard.Enabled then
			-- Self-heal: state says visible, but something external zeroed
			-- the size (clone inheritance, lost tween, outside writer) or it
			-- is stuck at the hidden park size. Re-pop instead of trusting the
			-- flag, and log the drift once so field reports of missing
			-- billboards carry the root cause.
			local baseSize = billboardBaseSize(billboard)
			local stuckHidden = isDegenerateSize(billboard.Size)
				or billboard.Size == scaleUDim2(baseSize, BILLBOARD_HIDDEN_SCALE)
			if stuckHidden and not isDegenerateSize(baseSize) then
				if not record.healWarned then
					record.healWarned = true
					warn("[UiEffects] Healed billboard stuck at zero size: " .. billboard:GetFullName())
				end
				record.allowPop = true
				UiEffects.PlayBillboardPop(billboard)
				record.allowPop = false
			end
			return
		end
		setGateHidden(billboard, false)
		record.visible = true
		record.closing = false
		record.allowPop = true
		UiEffects.PlayBillboardPop(billboard)
		record.allowPop = false
	elseif record.visible == true then
		playBillboardHide(billboard, record)
	elseif not record.closing then
		billboard.Size = scaleUDim2(billboardBaseSize(billboard), BILLBOARD_HIDDEN_SCALE)
		setGateHidden(billboard, true)
	end
end

local function ensureBillboardDistanceConnection()
	if billboardDistanceConnection then
		return
	end

	-- Distance gating only tracks player/camera movement, so it does not need
	-- frame-rate cadence; Enabled changes still update immediately through
	-- their own property signal.
	local elapsed = 0
	billboardDistanceConnection = RuntimeGuard.Connect(RunService.Heartbeat, "UiEffects.BillboardDistance", function(dt)
		elapsed += dt
		if elapsed < BILLBOARD_DISTANCE_CHECK_INTERVAL then return end
		elapsed = 0
		for billboard in pairs(distanceBillboards) do
			-- Skip while unparented rather than dropping the record: a
			-- billboard mid-reparent would otherwise be orphaned at whatever
			-- size the gate left it. Destroyed billboards clean up via their
			-- Destroying connection.
			if billboard.Parent ~= nil then
				updateDistanceBillboard(billboard)
			end
		end
	end)
end

function UiEffects.BindBillboardDistancePop(billboard)
	if not (billboard and billboard:IsA("BillboardGui")) then
		return
	end

	-- Prefer the stored authored MaxDistance: on a rebind (or a clone of a
	-- managed billboard) the live property already holds the managed
	-- sentinel, not the real gating distance.
	local maxDistance = billboard:GetAttribute(BILLBOARD_BASE_MAX_DISTANCE_ATTR)
	if type(maxDistance) ~= "number" or maxDistance <= 0 then
		maxDistance = billboard.MaxDistance
	end
	if type(maxDistance) ~= "number" or maxDistance <= 0 then
		return
	end

	UiEffects.BindBillboardPop(billboard)

	local record = {
		maxDistance = maxDistance,
		desiredEnabled = billboard.Enabled,
		visible = false,
		closing = false,
	}
	distanceBillboards[billboard] = record
	if maxDistance < math.huge then
		billboard:SetAttribute(BILLBOARD_BASE_MAX_DISTANCE_ATTR, maxDistance)
	end
	billboard.MaxDistance = BILLBOARD_MANAGED_MAX_DISTANCE

	RuntimeGuard.Connect(billboard:GetPropertyChangedSignal("Enabled"), "UiEffects.DistanceBillboardEnabled", function()
		record.desiredEnabled = billboard.Enabled
		updateDistanceBillboard(billboard)
	end)
	RuntimeGuard.Connect(billboard.Destroying, "UiEffects.DistanceBillboardDestroying", function()
		distanceBillboards[billboard] = nil
	end)

	ensureBillboardDistanceConnection()
	updateDistanceBillboard(billboard)
end

-- Wraps a gui's children in a CanvasGroup so the whole panel can fade as one
-- layer via GroupTransparency (BillboardGuis have no group transparency of
-- their own).
function UiEffects.WrapInCanvasGroup(container)
	local canvas = Instance.new("CanvasGroup")
	canvas.Name = "canvas"
	canvas.BackgroundTransparency = 1
	canvas.BorderSizePixel = 0
	canvas.Size = UDim2.fromScale(1, 1)
	for _, child in ipairs(container:GetChildren()) do
		child.Parent = canvas
	end
	canvas.Parent = container
	return canvas
end

function UiEffects.SetGroupTransparency(canvas, transparency, instant)
	if instant then
		canvas.GroupTransparency = transparency
		return
	end
	tween(canvas, GROUP_FADE_TWEEN, { GroupTransparency = transparency })
end

function UiEffects.SetTextStack(root, text)
	if not root then
		return
	end
	if root:IsA("TextLabel") or root:IsA("TextButton") then
		root.Text = text
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			descendant.Text = text
		end
	end
end

function UiEffects.SetButtonEnabled(button, enabled)
	if not button then
		return
	end
	button.Active = enabled
	button.AutoButtonColor = enabled
	if button:IsA("ImageButton") then
		button.ImageTransparency = enabled and 0 or 0.45
	end
	for _, descendant in ipairs(button:GetDescendants()) do
		if descendant:IsA("TextLabel") then
			descendant.TextTransparency = enabled and 0 or 0.35
		elseif descendant:IsA("ImageLabel") then
			descendant.ImageTransparency = enabled and 0 or 0.35
		end
	end
end

function UiEffects.FormatCurrency(amount)
	return NumberFormatter.Currency(amount)
end

function UiEffects.PreparePanel(panel)
	if not panel then
		return nil
	end

	local openPosition = panel.Position
	local openSize = panel.Size
	local closedPosition = UDim2.new(openPosition.X.Scale, openPosition.X.Offset, 1.18, openPosition.Y.Offset)
	local closedSize = scaleUDim2(openSize, 0.86)

	panel:SetAttribute("UiEffectsOpenXScale", openPosition.X.Scale)
	panel:SetAttribute("UiEffectsOpenXOffset", openPosition.X.Offset)
	panel:SetAttribute("UiEffectsOpenYScale", openPosition.Y.Scale)
	panel:SetAttribute("UiEffectsOpenYOffset", openPosition.Y.Offset)
	panel:SetAttribute("UiEffectsOpenSizeXScale", openSize.X.Scale)
	panel:SetAttribute("UiEffectsOpenSizeXOffset", openSize.X.Offset)
	panel:SetAttribute("UiEffectsOpenSizeYScale", openSize.Y.Scale)
	panel:SetAttribute("UiEffectsOpenSizeYOffset", openSize.Y.Offset)

	panel.Position = closedPosition
	panel.Size = closedSize
	panel.Visible = false

	return {
		openPosition = openPosition,
		openSize = openSize,
		closedPosition = closedPosition,
		closedSize = closedSize,
	}
end

function UiEffects.PlayOpen(panel, state, options)
	if not (panel and state) then
		return nil
	end
	options = type(options) == "table" and options or {}
	if options.silent ~= true then
		SoundEffects.Play(SoundEffects.Names.UiOpen)
	end
	panel.Visible = true
	panel.Position = state.closedPosition
	panel.Size = state.closedSize
	return tween(panel, OPEN_TWEEN, {
		Position = state.openPosition,
		Size = state.openSize,
	})
end

function UiEffects.PlayClose(panel, state, onComplete, options)
	if not (panel and state) then
		if onComplete then
			onComplete()
		end
		return nil
	end
	options = type(options) == "table" and options or {}
	if options.silent ~= true then
		SoundEffects.Play(SoundEffects.Names.UiClose)
	end
	local closeTween = tween(panel, CLOSE_TWEEN, {
		Position = state.closedPosition,
		Size = state.closedSize,
	})
	RuntimeGuard.Connect(closeTween.Completed, "UiEffects.PlayCloseCompleted", function()
		panel.Visible = false
		if onComplete then
			onComplete()
		end
	end)
	return closeTween
end

function UiEffects.PlayError()
	SoundEffects.Play(SoundEffects.Names.Error)
end

return UiEffects
