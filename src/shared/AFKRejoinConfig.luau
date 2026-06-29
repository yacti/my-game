local AFKRejoinConfig = {}

AFKRejoinConfig.IdleSeconds = 19 * 60
AFKRejoinConfig.ServerGraceSeconds = 10
AFKRejoinConfig.RequestRateSeconds = 30
AFKRejoinConfig.TeleportDataKind = "AFKRejoin"
AFKRejoinConfig.TeleportDataVersion = 1
AFKRejoinConfig.TeleportDataMaxAgeSeconds = 10 * 60
AFKRejoinConfig.CameraRestoreFrames = 18
AFKRejoinConfig.CameraZoomRestoreFrames = 30
AFKRejoinConfig.CameraRestoreFloorWaitSeconds = 10
AFKRejoinConfig.LoadingScreenDismissWaitSeconds = 40
AFKRejoinConfig.PendingAttributeSeconds = 60
AFKRejoinConfig.MinCameraZoomDistance = 0.5
AFKRejoinConfig.MaxCameraZoomDistance = 2048
AFKRejoinConfig.MaxLocalPositionAbs = 2048
AFKRejoinConfig.MaxWorldPositionAbs = 100000
AFKRejoinConfig.MinFieldOfView = 1
AFKRejoinConfig.MaxFieldOfView = 120

local CFRAME_COMPONENT_COUNT = 12
local ROTATION_COMPONENT_START = 4
local MAX_ROTATION_COMPONENT_ABS = 2

local VALID_CAMERA_TYPES = {
	Attach = true,
	Custom = true,
	Fixed = true,
	Follow = true,
	Orbital = true,
	Scriptable = true,
	Track = true,
	Watch = true,
}

local function isFiniteNumber(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function componentLimit(index, maxPositionAbs)
	if index < ROTATION_COMPONENT_START then
		return maxPositionAbs
	end
	return MAX_ROTATION_COMPONENT_ABS
end

function AFKRejoinConfig.IsFiniteNumber(value)
	return isFiniteNumber(value)
end

function AFKRejoinConfig.CFrameToArray(cframe)
	if typeof(cframe) ~= "CFrame" then
		return nil
	end

	local components = { cframe:GetComponents() }
	for index, component in ipairs(components) do
		if not isFiniteNumber(component) then
			return nil
		end
		if math.abs(component) > componentLimit(index, AFKRejoinConfig.MaxWorldPositionAbs) then
			return nil
		end
	end
	return components
end

function AFKRejoinConfig.SanitizeCFrameArray(value, maxPositionAbs)
	if type(value) ~= "table" then
		return nil
	end
	maxPositionAbs = math.max(tonumber(maxPositionAbs) or AFKRejoinConfig.MaxLocalPositionAbs, 0)

	local components = {}
	for index = 1, CFRAME_COMPONENT_COUNT do
		local component = value[index]
		if not isFiniteNumber(component) then
			return nil
		end
		if math.abs(component) > componentLimit(index, maxPositionAbs) then
			return nil
		end
		components[index] = component
	end

	return components
end

function AFKRejoinConfig.CFrameFromArray(value, maxPositionAbs)
	local components = AFKRejoinConfig.SanitizeCFrameArray(value, maxPositionAbs)
	if not components then
		return nil
	end

	return CFrame.new(table.unpack(components, 1, CFRAME_COMPONENT_COUNT))
end

function AFKRejoinConfig.ClampFieldOfView(value)
	if not isFiniteNumber(value) then
		return nil
	end
	return math.clamp(value, AFKRejoinConfig.MinFieldOfView, AFKRejoinConfig.MaxFieldOfView)
end

function AFKRejoinConfig.SanitizeCameraPayload(payload)
	if type(payload) ~= "table" then
		return nil
	end

	local localCFrame = AFKRejoinConfig.SanitizeCFrameArray(payload.localCFrame, AFKRejoinConfig.MaxLocalPositionAbs)
	local localFocus = AFKRejoinConfig.SanitizeCFrameArray(payload.localFocus, AFKRejoinConfig.MaxLocalPositionAbs)
	local fieldOfView = AFKRejoinConfig.ClampFieldOfView(payload.fieldOfView)
	if not (localCFrame and localFocus and fieldOfView) then
		return nil
	end

	local cameraType = type(payload.cameraType) == "string" and payload.cameraType or "Custom"
	if not VALID_CAMERA_TYPES[cameraType] then
		cameraType = "Custom"
	end

	local zoomDistance = tonumber(payload.zoomDistance)
	if
		not isFiniteNumber(zoomDistance)
		or zoomDistance < AFKRejoinConfig.MinCameraZoomDistance
		or zoomDistance > AFKRejoinConfig.MaxCameraZoomDistance
	then
		zoomDistance = nil
	end

	return {
		localCFrame = localCFrame,
		localFocus = localFocus,
		fieldOfView = fieldOfView,
		cameraType = cameraType,
		zoomDistance = zoomDistance,
	}
end

function AFKRejoinConfig.SanitizeTeleportData(data, currentPlaceId)
	if type(data) ~= "table" then
		return nil
	end
	if data.kind ~= AFKRejoinConfig.TeleportDataKind or data.version ~= AFKRejoinConfig.TeleportDataVersion then
		return nil
	end
	if tonumber(data.sourcePlaceId) ~= currentPlaceId then
		return nil
	end

	local issuedAt = tonumber(data.issuedAt)
	if not isFiniteNumber(issuedAt) then
		return nil
	end
	if math.abs(os.time() - issuedAt) > AFKRejoinConfig.TeleportDataMaxAgeSeconds then
		return nil
	end

	local character = type(data.character) == "table" and data.character or nil
	local characterLocalCFrame = character and AFKRejoinConfig.SanitizeCFrameArray(character.localCFrame, AFKRejoinConfig.MaxLocalPositionAbs) or nil
	if not characterLocalCFrame then
		return nil
	end

	return {
		character = {
			localCFrame = characterLocalCFrame,
		},
		camera = AFKRejoinConfig.SanitizeCameraPayload(data.camera),
		autoRollEnabled = data.autoRollEnabled == true,
		issuedAt = issuedAt,
		sourceJobId = type(data.sourceJobId) == "string" and data.sourceJobId or "",
	}
end

return AFKRejoinConfig
