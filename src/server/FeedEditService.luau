local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local FeedGrowthService = require(Server:WaitForChild("FeedGrowthService"))
local FeedMachines = require(Server:WaitForChild("feedMachines"))
local PetMotionService = require(Server:WaitForChild("PetMotionService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService = require(Server:WaitForChild("PlotService"))
local TelemetryService = require(Server:WaitForChild("TelemetryService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local FeedEditService = {}

local EDIT_MODE_ATTR = "EditMode"
local DEFAULT_TOGGLE_RATE_SECONDS = 0.15
local DEFAULT_MOVE_RATE_SECONDS = 0.05
local DEFAULT_MOVE_DISTANCE = 1000
local FLOOR_Y_TOLERANCE_BELOW = 5
local FLOOR_Y_TOLERANCE_ABOVE = 14

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
	if key == nil or map[key] then return false end
	map[key] = true
	local ok = RuntimeGuard.Run("FeedEditService.Handler", callback)
	map[key] = nil
	return ok
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

local function isPlayerOnFloor(player, floor)
	local root = rootPart(player)
	if not root or not floor then return false end

	local localPosition = floor.CFrame:PointToObjectSpace(root.Position)
	return math.abs(localPosition.X) <= floor.Size.X / 2
		and math.abs(localPosition.Z) <= floor.Size.Z / 2
		and localPosition.Y >= floor.Size.Y / 2 - FLOOR_Y_TOLERANCE_BELOW
		and localPosition.Y <= floor.Size.Y / 2 + FLOOR_Y_TOLERANCE_ABOVE
end

local function resolvePlaceableTarget(plot, target)
	if typeof(target) ~= "Instance" or not target:IsDescendantOf(plot) then
		return nil
	end

	local current = target
	while current and current ~= plot do
		local feedType = current:GetAttribute(State.Feed.Type)
		local cosmeticId = current:GetAttribute(State.Cosmetic.Id)
		if (current:IsA("BasePart") or current:IsA("Model")) and (
			(type(feedType) == "string" and feedType ~= "" and current:GetAttribute(State.Feed.Index) ~= nil)
			or (type(cosmeticId) == "string" and cosmeticId ~= "" and current:GetAttribute(State.Cosmetic.Index) ~= nil)
		) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function isMatureFeed(feed)
	return feed ~= nil
		and (feed:IsA("BasePart") or feed:IsA("Model"))
		and type(feed:GetAttribute(State.Feed.Type)) == "string"
		and feed:GetAttribute(State.Feed.Type) ~= ""
		and feed:GetAttribute(State.Feed.Index) ~= nil
		and not FeedGrowthService.IsGrowing(feed)
end

local function isCosmetic(cosmetic)
	return cosmetic ~= nil
		and (cosmetic:IsA("BasePart") or cosmetic:IsA("Model"))
		and type(cosmetic:GetAttribute(State.Cosmetic.Id)) == "string"
		and cosmetic:GetAttribute(State.Cosmetic.Id) ~= ""
		and cosmetic:GetAttribute(State.Cosmetic.Index) ~= nil
end

function FeedEditService.Start(config)
	config = config or {}
	local snapshotProfileState = config.snapshotProfileState
	local isGameplayBlocked = type(config.isGameplayBlocked) == "function" and config.isGameplayBlocked or function()
		return false
	end
	local toggleRateSeconds = tonumber(config.toggleRateSeconds) or DEFAULT_TOGGLE_RATE_SECONDS
	local moveRateSeconds = tonumber(config.moveRateSeconds) or DEFAULT_MOVE_RATE_SECONDS
	local moveDistance = tonumber(config.moveDistance) or DEFAULT_MOVE_DISTANCE

	local toggleLastFire = {}
	local moveLastFire = {}
	local moveLocks = {}

	local FeedEditModeRequest = Remotes.get(Remotes.Names.FeedEditModeRequest)
	local FeedMoveRequest = Remotes.get(Remotes.Names.FeedMoveRequest)
	local FeedMoveResult = Remotes.get(Remotes.Names.FeedMoveResult)

	local function sendMoveResult(player, requestId, success, reason, targetCFrame)
		if type(requestId) ~= "number" then return end
		RuntimeGuard.Run("FeedEditService.FireMoveResult", function()
			FeedMoveResult:FireClient(player, requestId, success, reason, targetCFrame)
		end)
	end

	local function recordMoveReject(player, reason, extra)
		local fields = TelemetryService.ForPlayer(player, extra or {})
		fields.reason = reason
		TelemetryService.Warn("feed_move_rejected", fields)
	end

	RuntimeGuard.Connect(Players.PlayerRemoving, "FeedEditService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key == nil then return end
		toggleLastFire[key] = nil
		moveLastFire[key] = nil
		moveLocks[key] = nil
	end)

	RuntimeGuard.Connect(FeedEditModeRequest.OnServerEvent, "FeedEditService.EditModeRequest", function(player, enabled)
		if type(enabled) ~= "boolean" then return end
		if isGameplayBlocked(player) then
			player:SetAttribute(EDIT_MODE_ATTR, false)
			return
		end
		if not consumeRateLimit(toggleLastFire, player, toggleRateSeconds) then return end

		if not enabled then
			player:SetAttribute(EDIT_MODE_ATTR, false)
			return
		end

		local plot = PlotService.GetPlayerPlot(player)
		local profile = PlayerDataService.GetProfile(player)
		local floor = PlotService.GetFloor(plot)
		if not plot or not profile or not floor or not isPlayerOnFloor(player, floor) then
			player:SetAttribute(EDIT_MODE_ATTR, false)
			return
		end

		player:SetAttribute(EDIT_MODE_ATTR, true)
	end)

	RuntimeGuard.Connect(FeedMoveRequest.OnServerEvent, "FeedEditService.MoveRequest", function(player, requestId, target, cframe)
		if isGameplayBlocked(player) then
			player:SetAttribute(EDIT_MODE_ATTR, false)
			sendMoveResult(player, requestId, false, "busy")
			return
		end
		if not consumeRateLimit(moveLastFire, player, moveRateSeconds) then
			sendMoveResult(player, requestId, false, "rate-limited")
			return
		end
		if not isValidCFrame(cframe) then
			recordMoveReject(player, "invalid-cframe")
			sendMoveResult(player, requestId, false, "invalid-cframe")
			return
		end
		if player:GetAttribute(EDIT_MODE_ATTR) ~= true then
			sendMoveResult(player, requestId, false, "not-editing")
			return
		end
		local key = userKey(player)
		if key == nil then
			sendMoveResult(player, requestId, false, "invalid-player")
			return
		end
		if moveLocks[key] then
			sendMoveResult(player, requestId, false, "busy")
			return
		end

		withPlayerLock(moveLocks, player, function()
			local plot = PlotService.GetPlayerPlot(player)
			local profile = PlayerDataService.GetProfile(player)
			if not plot or not profile then
				sendMoveResult(player, requestId, false, "no-plot")
				return
			end

			local placeable = resolvePlaceableTarget(plot, target)
			local movingFeed = isMatureFeed(placeable)
			local movingCosmetic = isCosmetic(placeable)
			if not (movingFeed or movingCosmetic) then
				sendMoveResult(player, requestId, false, "invalid-target")
				return
			end

			local feedType = movingFeed and placeable:GetAttribute(State.Feed.Type) or nil
			local cosmeticId = movingCosmetic and placeable:GetAttribute(State.Cosmetic.Id) or nil
			local floor = PlotService.GetFloor(plot)
			if not floor then
				sendMoveResult(player, requestId, false, "no-floor")
				return
			end
			if not isPlayerOnFloor(player, floor) then
				player:SetAttribute(EDIT_MODE_ATTR, false)
				sendMoveResult(player, requestId, false, "not-editing")
				return
			end

			local localCF = floor.CFrame:ToObjectSpace(cframe)
			if math.abs(localCF.X) > floor.Size.X / 2 or math.abs(localCF.Z) > floor.Size.Z / 2 then
				sendMoveResult(player, requestId, false, "out-of-bounds")
				return
			end

			local snappedLX = math.round(localCF.X)
			local snappedLZ = math.round(localCF.Z)
			local _, lry, _ = localCF:ToOrientation()
			local snappedLRY = math.round(lry / (math.pi / 2)) * (math.pi / 2)
			local snappedWorldPosition = floor.CFrame:PointToWorldSpace(Vector3.new(snappedLX, 0, snappedLZ))

			if not isPlayerNearPosition(player, snappedWorldPosition, moveDistance) then
				recordMoveReject(player, "too-far", {
					feedType = feedType,
					cosmeticId = cosmeticId,
					plot = plot,
					target = placeable,
					position = snappedWorldPosition,
				})
				sendMoveResult(player, requestId, false, "too-far")
				return
			end
			local fits
			if movingCosmetic then
				fits = PlotService.CosmeticPlacementFitsOnFloor(plot, cosmeticId, snappedLX, snappedLZ, snappedLRY)
			else
				fits = PlotService.FeedPlacementFitsOnFloor(plot, feedType, snappedLX, snappedLZ, snappedLRY)
			end
			if not fits then
				sendMoveResult(player, requestId, false, "out-of-bounds")
				return
			end
			local overlaps
			if movingCosmetic then
				overlaps = PlotService.CosmeticPlacementOverlapsExcept(plot, cosmeticId, snappedLX, snappedLZ, snappedLRY, placeable)
			else
				overlaps = PlotService.FeedPlacementOverlapsExcept(plot, feedType, snappedLX, snappedLZ, snappedLRY, placeable)
			end
			if overlaps then
				sendMoveResult(player, requestId, false, "overlap")
				return
			end

			local oldLX, oldLZ, oldLRY = PlotService.WorldPivotToFloorLocal(floor, placeable:GetPivot())
			local movedCFrame
			if movingCosmetic then
				movedCFrame = PlotService.RepositionCosmetic(plot, placeable, snappedLX, snappedLZ, snappedLRY)
			else
				-- Resync before pivoting so the move replicates fruit at its
				-- true current scale instead of the last published one.
				FeedMachines.ResyncVisualScales(placeable)
				movedCFrame = PlotService.RepositionFeed(plot, placeable, snappedLX, snappedLZ, snappedLRY)
			end
			if not movedCFrame then
				sendMoveResult(player, requestId, false, "move-failed")
				return
			end

			PetMotionService.RefreshPlotRoutes(plot)
			if type(snapshotProfileState) == "function" then
				local snapshotOk = snapshotProfileState(player, plot, profile)
				if not snapshotOk then
					if movingCosmetic then
						PlotService.RepositionCosmetic(plot, placeable, oldLX, oldLZ, oldLRY)
					else
						FeedMachines.ResyncVisualScales(placeable)
						PlotService.RepositionFeed(plot, placeable, oldLX, oldLZ, oldLRY)
					end
					PetMotionService.RefreshPlotRoutes(plot)
					sendMoveResult(player, requestId, false, "save-failed")
					return
				end
			end
			sendMoveResult(player, requestId, true, nil, movedCFrame)
			TelemetryService.Record("feed_move_succeeded", TelemetryService.ForPlayer(player, {
				feedType = feedType,
				cosmeticId = cosmeticId,
				target = placeable,
				plot = plot,
			}))
		end)
	end)
end

return FeedEditService
