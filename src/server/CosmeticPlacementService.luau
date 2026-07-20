local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local CosmeticTools = require(Server:WaitForChild("CosmeticTools"))
local PetMotionService = require(Server:WaitForChild("PetMotionService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService = require(Server:WaitForChild("PlotService"))
local TelemetryService = require(Server:WaitForChild("TelemetryService"))
local ToolGrantService = require(Server:WaitForChild("ToolGrantService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Cosmetics = require(Shared:WaitForChild("Cosmetics"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local CosmeticPlacementService = {}

local DEFAULT_RATE_SECONDS = 0.25
local DEFAULT_PLACE_DISTANCE = 24

local function userKey(player)
	return player and player.UserId or nil
end

local function consumeRateLimit(map, player, interval)
	local key = userKey(player)
	if key == nil then return false end
	local now = os.clock()
	local previous = map[key] or 0
	if now - previous < interval then return false end
	map[key] = now
	return true
end

local function withPlayerLock(map, player, callback)
	local key = userKey(player)
	if key == nil or map[key] then return end
	map[key] = true
	RuntimeGuard.Run("CosmeticPlacementService.Handler", callback)
	map[key] = nil
end

local function isFinite(n)
	return type(n) == "number" and n == n and math.abs(n) < math.huge
end

local function isValidCFrame(value)
	if typeof(value) ~= "CFrame" then return false end
	local components = { value:GetComponents() }
	for _, component in ipairs(components) do
		if not isFinite(component) then return false end
	end
	return true
end

local function rootPart(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root or nil
end

local function isPlayerNearPosition(player, position, maxDistance)
	local root = rootPart(player)
	return root ~= nil
		and typeof(position) == "Vector3"
		and (root.Position - position).Magnitude <= maxDistance
end

function CosmeticPlacementService.Start(config)
	config = config or {}
	local snapshotProfileState = config.snapshotProfileState
	local isGameplayBlocked = type(config.isGameplayBlocked) == "function" and config.isGameplayBlocked or function()
		return false
	end
	local rateSeconds = tonumber(config.rateSeconds) or DEFAULT_RATE_SECONDS
	local placeDistance = tonumber(config.placeDistance) or DEFAULT_PLACE_DISTANCE
	local lastFire = {}
	local locks = {}

	local PlaceCosmetic = Remotes.get(Remotes.Names.PlaceCosmetic)
	local PlaceCosmeticResult = Remotes.get(Remotes.Names.PlaceCosmeticResult)

	local function sendPlaceResult(player, requestId, success, reason)
		if type(requestId) ~= "number" then return end
		RuntimeGuard.Run("CosmeticPlacementService.FireResult", function()
			PlaceCosmeticResult:FireClient(player, requestId, success, reason)
		end)
	end

	local function recordPlacementReject(player, reason, extra)
		local fields = TelemetryService.ForPlayer(player, extra or {})
		fields.reason = reason
		TelemetryService.Warn("cosmetic_placement_rejected", fields)
	end

	local function restoreConsumedTool(player, cosmeticId, favourite)
		local backpack = player and player:FindFirstChildOfClass("Backpack")
		if not backpack then
			return false
		end
		local replacement = CosmeticTools.MakeCosmeticTool(cosmeticId)
		if not replacement then
			return false
		end
		ToolIdentity.SetFavourite(replacement, favourite == true)
		return ToolGrantService.GrantTool(player, replacement)
	end

	RuntimeGuard.Connect(Players.PlayerRemoving, "CosmeticPlacementService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key == nil then return end
		lastFire[key] = nil
		locks[key] = nil
	end)

	RuntimeGuard.Connect(PlaceCosmetic.OnServerEvent, "CosmeticPlacementService.PlaceCosmetic", function(player, requestId, cframe, toolGuid)
		if isGameplayBlocked(player) then
			sendPlaceResult(player, requestId, false, "busy")
			return
		end
		if not consumeRateLimit(lastFire, player, rateSeconds) then
			sendPlaceResult(player, requestId, false, "rate-limited")
			return
		end
		if not isValidCFrame(cframe) then
			recordPlacementReject(player, "invalid-cframe")
			sendPlaceResult(player, requestId, false, "invalid-cframe")
			return
		end
		local plot = PlotService.GetPlayerPlot(player)
		if not plot then
			recordPlacementReject(player, "no-plot")
			sendPlaceResult(player, requestId, false, "no-plot")
			return
		end
		local key = userKey(player)
		if key == nil then
			sendPlaceResult(player, requestId, false, "invalid-player")
			return
		end
		if locks[key] then
			sendPlaceResult(player, requestId, false, "busy")
			return
		end

		withPlayerLock(locks, player, function()
			if not player.Character then
				recordPlacementReject(player, "no-character")
				sendPlaceResult(player, requestId, false, "no-character")
				return
			end
			local profile = PlayerDataService.GetProfile(player)
			if not profile then
				sendPlaceResult(player, requestId, false, "no-profile")
				return
			end
			local tool = ToolIdentity.FindEquippedByGuid(player, toolGuid, CosmeticTools.IsCosmeticTool)
			if not tool then
				sendPlaceResult(player, requestId, false, "no-cosmetic-tool")
				return
			end
			local cosmeticId = CosmeticTools.CosmeticIdOf(tool)
			local wasFavourite = ToolIdentity.IsFavourite(tool)
			if type(cosmeticId) ~= "string" or cosmeticId == "" then
				sendPlaceResult(player, requestId, false, "no-cosmetic-tool")
				return
			end

			local floor = PlotService.GetFloor(plot)
			if not floor then
				sendPlaceResult(player, requestId, false, "no-floor")
				return
			end

			local template = Cosmetics.GetTemplate(cosmeticId)
			if not template then
				sendPlaceResult(player, requestId, false, "no-template")
				return
			end

			local localCF = floor.CFrame:ToObjectSpace(cframe)
			if math.abs(localCF.X) > floor.Size.X / 2 or
			   math.abs(localCF.Z) > floor.Size.Z / 2 then
				sendPlaceResult(player, requestId, false, "out-of-bounds")
				return
			end
			local snappedLX = math.round(localCF.X)
			local snappedLZ = math.round(localCF.Z)
			local _, lry, _ = localCF:ToOrientation()
			local snappedLRY = math.round(lry / (math.pi / 2)) * (math.pi / 2)
			local snappedWorldPosition = floor.CFrame:PointToWorldSpace(Vector3.new(snappedLX, 0, snappedLZ))
			if not isPlayerNearPosition(player, snappedWorldPosition, placeDistance) then
				recordPlacementReject(player, "too-far", {
					cosmeticId = cosmeticId,
					plot = plot,
					position = snappedWorldPosition,
				})
				sendPlaceResult(player, requestId, false, "too-far")
				return
			end
			if not PlotService.CosmeticPlacementFitsOnFloor(plot, cosmeticId, snappedLX, snappedLZ, snappedLRY) then
				sendPlaceResult(player, requestId, false, "out-of-bounds")
				return
			end
			if PlotService.CosmeticPlacementOverlaps(plot, cosmeticId, snappedLX, snappedLZ, snappedLRY) then
				sendPlaceResult(player, requestId, false, "overlap")
				return
			end

			local cosmetic = PlotService.PlaceCosmetic(plot, cosmeticId, snappedLX, snappedLZ, snappedLRY)
			if not cosmetic then
				sendPlaceResult(player, requestId, false, "place-failed")
				return
			end

			if not ToolIdentity.DestroyIfGuidMatches(tool, toolGuid) then
				cosmetic:Destroy()
				sendPlaceResult(player, requestId, false, "no-cosmetic-tool")
				return
			end

			PetMotionService.RefreshPlotRoutes(plot)
			if profile and type(snapshotProfileState) == "function" then
				local snapshotOk = snapshotProfileState(player, plot, profile)
				if not snapshotOk then
					cosmetic:Destroy()
					PetMotionService.RefreshPlotRoutes(plot)
					restoreConsumedTool(player, cosmeticId, wasFavourite)
					sendPlaceResult(player, requestId, false, "save-failed")
					return
				end
			end

			sendPlaceResult(player, requestId, true, nil)
			TelemetryService.Record("cosmetic_placement_succeeded", TelemetryService.ForPlayer(player, {
				cosmeticId = cosmeticId,
				plot = plot,
			}))
		end)
	end)
end

return CosmeticPlacementService
