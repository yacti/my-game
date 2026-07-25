local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Server = script.Parent
local PlotService = require(Server:WaitForChild("PlotService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BeeEvent = require(Shared:WaitForChild("BeeEvent"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local HomeTeleportService = {}

local REQUEST_COOLDOWN_SECONDS = 1.5
local SPAWN_CLEARANCE_PADDING = 0.5
local DEFAULT_CHARACTER_HEIGHT = 6

local requestRemote = Remotes.get(Remotes.Names.HomeTeleportRequest)
local eventRequestRemote = Remotes.get(Remotes.Names.EventTeleportRequest)
local started = false
local lastRequestByUserId = {}

local function userKey(player)
	return player and player.UserId or nil
end

local function canRequest(player)
	local key = userKey(player)
	if not key then
		return false
	end

	local now = os.clock()
	local last = lastRequestByUserId[key]
	if last and now - last < REQUEST_COOLDOWN_SECONDS then
		return false
	end
	lastRequestByUserId[key] = now
	return true
end

local function spawnLocationFor(player)
	local plot = PlotService.GetPlayerPlot(player)
	if not plot then
		return nil
	end

	local spawnLocation = player.RespawnLocation
	if not (spawnLocation and spawnLocation:IsA("SpawnLocation") and spawnLocation:IsDescendantOf(plot)) then
		spawnLocation = plot:FindFirstChild("SpawnLocation")
	end
	if spawnLocation and spawnLocation:IsA("SpawnLocation") and spawnLocation:IsDescendantOf(plot) then
		return spawnLocation
	end
	return nil
end

local function characterParts(player)
	local character = player.Character
	if not (character and character:IsA("Model") and character:IsDescendantOf(Workspace)) then
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

	return character, humanoid, root
end

local function characterHeight(character)
	local ok, _, size = pcall(function()
		return character:GetBoundingBox()
	end)
	if ok and typeof(size) == "Vector3" then
		return math.max(size.Y, DEFAULT_CHARACTER_HEIGHT)
	end
	return DEFAULT_CHARACTER_HEIGHT
end

local function clearAssemblyVelocity(character)
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function teleportToPart(player, part)
	local character, humanoid = characterParts(player)
	if not (part and character) then
		return
	end

	if not canRequest(player) then
		return
	end

	local yOffset = (part.Size.Y * 0.5)
		+ (characterHeight(character) * 0.5)
		+ SPAWN_CLEARANCE_PADDING
	local targetCFrame = part.CFrame + (part.CFrame.UpVector * yOffset)

	if humanoid then
		humanoid.Sit = false
		humanoid.PlatformStand = false
	end

	character:PivotTo(targetCFrame)
	clearAssemblyVelocity(character)
end

local function teleportHome(player)
	teleportToPart(player, spawnLocationFor(player))
end

local function eventTeleportPart()
	local eventFolder = BeeEvent.FindMapFolder()
	local part = eventFolder and eventFolder:FindFirstChild(BeeEvent.TeleportPartName)
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

local function teleportToEvent(player)
	teleportToPart(player, eventTeleportPart())
end

function HomeTeleportService.Start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Connect(requestRemote.OnServerEvent, "HomeTeleportService.Request", teleportHome)
	RuntimeGuard.Connect(eventRequestRemote.OnServerEvent, "HomeTeleportService.EventRequest", teleportToEvent)
	RuntimeGuard.Connect(Players.PlayerRemoving, "HomeTeleportService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			lastRequestByUserId[key] = nil
		end
	end)
end

return HomeTeleportService
