local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService = require(Server:WaitForChild("PlotService"))
local RollService = require(Server:WaitForChild("RollService"))
local SafeTeleport = require(Server:WaitForChild("SafeTeleport"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AFKRejoinConfig = require(Shared:WaitForChild("AFKRejoinConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local AFKRejoinService = {}

local requestRemote = Remotes.get(Remotes.Names.AFKRejoinRequest)
local restoreRemote = Remotes.get(Remotes.Names.AFKRejoinRestore)

local started = false
local joinedAtByUserId = {}
local lastRequestByUserId = {}
local locks = {}

local function setPendingAttribute(player, pending)
	if player and player.Parent then
		player:SetAttribute(State.Player.AFKRejoinPending, pending == true or nil)
	end
end

local function clearPendingAttributeLater(player)
	task.delay(AFKRejoinConfig.PendingAttributeSeconds, function()
		if player and player.Parent and player:GetAttribute(State.Player.AFKRejoinPending) == true then
			setPendingAttribute(player, false)
		end
	end)
end

local function userKey(player)
	return player and player.UserId or nil
end

local function minimumSessionSeconds()
	return math.max(AFKRejoinConfig.IdleSeconds - AFKRejoinConfig.ServerGraceSeconds, 0)
end

local function canRequest(player)
	local key = userKey(player)
	if not key then
		return false, "invalid-player"
	end

	local joinedAt = joinedAtByUserId[key]
	if not joinedAt or os.clock() - joinedAt < minimumSessionSeconds() then
		return false, "too-early"
	end

	local now = os.clock()
	local last = lastRequestByUserId[key]
	if last and now - last < AFKRejoinConfig.RequestRateSeconds then
		return false, "rate-limited"
	end
	lastRequestByUserId[key] = now
	return true, "ok"
end

local function characterPivot(player)
	local character = player.Character
	if not (character and character:IsA("Model") and character:IsDescendantOf(workspace)) then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then
		return nil
	end

	return character:GetPivot()
end

local function clearAssemblyVelocity(character)
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function localCFrameFor(plot, worldCFrame)
	local floor = PlotService.GetFloor(plot)
	if not (floor and typeof(worldCFrame) == "CFrame") then
		return nil
	end
	local localCFrame = floor.CFrame:ToObjectSpace(worldCFrame)
	return AFKRejoinConfig.CFrameToArray(localCFrame)
end

local function buildTeleportData(player, plot, cameraPayload)
	local pivot = characterPivot(player)
	if not pivot then
		return nil, "no-character"
	end

	local characterLocalCFrame = localCFrameFor(plot, pivot)
	if not characterLocalCFrame then
		return nil, "no-floor"
	end

	return {
		kind = AFKRejoinConfig.TeleportDataKind,
		version = AFKRejoinConfig.TeleportDataVersion,
		issuedAt = os.time(),
		sourcePlaceId = game.PlaceId,
		sourceJobId = game.JobId,
		autoRollEnabled = RollService.IsAutoRollEnabled(player),
		character = {
			localCFrame = characterLocalCFrame,
		},
		camera = AFKRejoinConfig.SanitizeCameraPayload(cameraPayload),
	}, "ok"
end

local function teleportPlayer(player, cameraPayload)
	local key = userKey(player)
	if not key or locks[key] then
		return
	end

	locks[key] = true
	local ok, code = RuntimeGuard.Run("AFKRejoinService.Teleport", function()
		local allowed, allowedCode = canRequest(player)
		if not allowed then
			return false, allowedCode
		end

		local profile = PlayerDataService.GetProfile(player)
		if not profile then
			return false, "no-profile"
		end

		local plot = PlotService.GetPlayerPlot(player)
		if not plot then
			return false, "no-plot"
		end

		local teleportData, dataCode = buildTeleportData(player, plot, cameraPayload)
		if not teleportData then
			return false, dataCode
		end

		local options = Instance.new("TeleportOptions")
		options:SetTeleportData(teleportData)
		return SafeTeleport(game.PlaceId, { player }, options)
	end)
	locks[key] = nil

	if ok ~= true or code == false then
		warn(string.format("[AFKRejoinService] Rejoin request failed for user %s: %s", tostring(key), tostring(code)))
		return false
	end
	return true
end

function AFKRejoinService.GetJoinData(player)
	local ok, joinData = RuntimeGuard.Run("AFKRejoinService.GetJoinData", function()
		return player:GetJoinData()
	end)
	if ok ~= true or type(joinData) ~= "table" then
		return nil
	end

	return AFKRejoinConfig.SanitizeTeleportData(joinData.TeleportData, game.PlaceId)
end

function AFKRejoinService.MarkPending(player, data)
	local pending = type(data) == "table"
	setPendingAttribute(player, pending)
	if pending then
		clearPendingAttributeLater(player)
	end
end

function AFKRejoinService.RestoreCharacter(player, plot, data)
	if type(data) ~= "table" then
		return false, "missing-data"
	end

	local floor = PlotService.GetFloor(plot)
	local localCFrame = AFKRejoinConfig.CFrameFromArray(data.character and data.character.localCFrame, AFKRejoinConfig.MaxLocalPositionAbs)
	local character = player.Character
	if not (floor and localCFrame and character and character:IsA("Model") and character:IsDescendantOf(workspace)) then
		return false, "not-ready"
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		root = character:WaitForChild("HumanoidRootPart", 5)
	end
	if not (root and root:IsA("BasePart")) then
		return false, "no-root"
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Sit = false
		humanoid.PlatformStand = false
	end

	character:PivotTo(floor.CFrame * localCFrame)
	clearAssemblyVelocity(character)
	return true, "ok"
end

function AFKRejoinService.FireCameraRestore(player, data)
	if type(data) ~= "table" or type(data.camera) ~= "table" then
		return false
	end
	restoreRemote:FireClient(player, data.camera)
	return true
end

function AFKRejoinService.Start()
	if started then
		return
	end
	started = true

	for _, player in ipairs(Players:GetPlayers()) do
		local key = userKey(player)
		if key then
			joinedAtByUserId[key] = os.clock()
		end
	end

	RuntimeGuard.Connect(Players.PlayerAdded, "AFKRejoinService.PlayerAdded", function(player)
		local key = userKey(player)
		if key then
			joinedAtByUserId[key] = os.clock()
		end
	end)

	RuntimeGuard.Connect(Players.PlayerRemoving, "AFKRejoinService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			joinedAtByUserId[key] = nil
			lastRequestByUserId[key] = nil
			locks[key] = nil
		end
		setPendingAttribute(player, false)
	end)

	RuntimeGuard.Connect(requestRemote.OnServerEvent, "AFKRejoinService.Request", function(player, payload)
		teleportPlayer(player, payload)
	end)
end

return AFKRejoinService
