local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

-- Single owner for temporary camera FOV zooms (menus, evolution cinematics).
--
-- Each effect used to snapshot Workspace.CurrentCamera.FieldOfView as its own
-- "restore to" value. When two overlapped, the second one sampled a FOV that
-- was still mid-tween from the first and restored to that instead of the real
-- resting value, leaving the camera permanently zoomed: closing the pet skin
-- confirmation dialog and applying the skin does exactly this, because the cue
-- lands inside the menu's close tween.
--
-- Holding the base here fixes that: it is captured once, when the first holder
-- arrives, and retained until every holder has released *and* the restore tween
-- has finished, so a zoom that starts mid-restore reuses the true base.
local CameraFovZoom = {}

local MIN_FOV = 40
local FALLBACK_FOV = 70

local holders = {}
local holderCount = 0
local nextToken = 0
local baseFov = nil
local activeTween = nil

local function cancelActiveTween()
	if activeTween then
		if activeTween.PlaybackState == Enum.PlaybackState.Playing then
			activeTween:Cancel()
		end
		activeTween = nil
	end
end

-- The deepest request wins rather than stacking, so each effect still zooms
-- exactly as far as it asked to and releasing one falls back to the next.
local function deepestAmount()
	local deepest = 0
	for _, amount in pairs(holders) do
		if amount > deepest then
			deepest = amount
		end
	end
	return deepest
end

local function retarget(tweenInfo)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	cancelActiveTween()
	activeTween = TweenService:Create(camera, tweenInfo, {
		FieldOfView = math.max((baseFov or camera.FieldOfView) - deepestAmount(), MIN_FOV),
	})
	activeTween:Play()
end

local function restore(tweenInfo)
	local camera = Workspace.CurrentCamera
	local target = baseFov or FALLBACK_FOV

	cancelActiveTween()
	if not camera then
		baseFov = nil
		return
	end

	local tween = TweenService:Create(camera, tweenInfo, { FieldOfView = target })
	activeTween = tween
	tween.Completed:Connect(function(state)
		-- Only a restore that ran to completion unclaimed may drop the base. A
		-- cancelled one means someone else is driving the FOV now — including an
		-- outside writer, whose tween cancels ours implicitly — and re-sampling
		-- after that is exactly the drift this module exists to prevent.
		if state ~= Enum.PlaybackState.Completed then
			return
		end
		if activeTween == tween and holderCount == 0 then
			activeTween = nil
			baseFov = nil
		end
	end)
	tween:Play()
end

-- amount: how many degrees to zoom in by. Returns an idempotent release().
function CameraFovZoom.Zoom(amount, inTween, outTween)
	amount = math.max(tonumber(amount) or 0, 0)

	local camera = Workspace.CurrentCamera
	if baseFov == nil then
		-- No holders and no restore in flight, so the camera is at rest and this
		-- reading is the value every holder in this run will restore to.
		baseFov = camera and camera.FieldOfView or FALLBACK_FOV
	end

	nextToken += 1
	local token = nextToken
	holders[token] = amount
	holderCount += 1
	retarget(inTween)

	local released = false
	return function()
		if released then
			return
		end
		released = true

		holders[token] = nil
		holderCount = math.max(holderCount - 1, 0)
		if holderCount > 0 then
			retarget(outTween)
			return
		end
		restore(outTween)
	end
end

-- Exposed for tests and diagnostics; nil once the camera is back at rest.
function CameraFovZoom.BaseFov()
	return baseFov
end

return CameraFovZoom
