local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local FeedGrowthService = require(Server:WaitForChild("FeedGrowthService"))
local FeedMachines = require(Server:WaitForChild("feedMachines"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local PetMotionService = require(Server:WaitForChild("PetMotionService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService = require(Server:WaitForChild("PlotService"))
local TelemetryService = require(Server:WaitForChild("TelemetryService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Shovel = require(Shared:WaitForChild("Shovel"))
local State = require(Shared:WaitForChild("State"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local ShovelService = {}

local DEFAULT_RATE_SECONDS = 0.25
local DEFAULT_DELETE_DISTANCE = 18

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
	local ok = RuntimeGuard.Run("ShovelService.Handler", callback)
	map[key] = nil
	return ok
end

local function rootPart(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root or nil
end

local function equippedShovel(player, toolGuid)
	return ToolIdentity.FindEquippedByGuid(player, toolGuid, Shovel.IsTool)
end

local function isPlayerNearInstance(player, instance, maxDistance)
	local root = rootPart(player)
	if not (root and instance and instance.Parent) then
		return false
	end
	return (root.Position - instance:GetPivot().Position).Magnitude <= maxDistance
end

local function resolveFeedTarget(plot, target)
	if typeof(target) ~= "Instance" or not target:IsDescendantOf(plot) then
		return nil
	end

	local current = target
	while current and current ~= plot do
		if (current:IsA("BasePart") or current:IsA("Model"))
			and type(current:GetAttribute(State.Feed.Type)) == "string"
			and current:GetAttribute(State.Feed.Type) ~= ""
			and current:GetAttribute(State.Feed.Index) ~= nil then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function isPlant(feed)
	if not feed then
		return false
	end
	if FeedGrowthService.IsGrowing(feed) then
		return true
	end

	local feedClass = feed:GetAttribute(State.Feed.Class)
	if type(feedClass) ~= "string" or feedClass == "" then
		feedClass = FeedMachines.GetClass(feed:GetAttribute(State.Feed.Type))
	end
	return feedClass == "Patch" or feedClass == "Tree"
end

local function placementFromFeed(plot, feed)
	local floor = PlotService.GetFloor(plot)
	local feedType = feed and feed:GetAttribute(State.Feed.Type)
	local feedIndex = feed and feed:GetAttribute(State.Feed.Index)
	if not (floor and type(feedType) == "string" and feedType ~= "" and type(feedIndex) == "number") then
		return nil
	end
	local lx, lz, lry = PlotService.WorldPivotToFloorLocal(floor, feed:GetPivot())
	local placement = {
		type = feedType,
		index = feedIndex,
		lx = lx,
		lz = lz,
		lry = lry,
	}
	local extras = FeedGrowthService.IsGrowing(feed) and FeedGrowthService.Serialize(feed) or FeedMachines.Serialize(feed)
	if type(extras) == "table" then
		for key, value in pairs(extras) do
			placement[key] = value
		end
	end
	return placement
end

local function restoreFeedPlacement(plot, player, placement)
	if type(placement) ~= "table" then
		return nil
	end
	if placement.phase == FeedGrowthService.Phase then
		return FeedGrowthService.RestorePlacement(plot, player, placement, placement.index)
	end
	local restored = PlotService.PlaceFeedWithIndex(
		plot,
		placement.type,
		placement.index,
		placement.lx or 0,
		placement.lz or 0,
		placement.lry or 0
	)
	if restored then
		local setupOk = FeedMachines.Setup(restored, plot, player)
		if not setupOk then
			restored:Destroy()
			return nil
		end
		FeedMachines.Apply(restored, placement)
	end
	return restored
end

function ShovelService.Start(config)
	config = config or {}
	local snapshotProfileState = config.snapshotProfileState
	local rateSeconds = tonumber(config.rateSeconds) or DEFAULT_RATE_SECONDS
	local deleteDistance = tonumber(config.deleteDistance) or DEFAULT_DELETE_DISTANCE

	local lastFire = {}
	local locks = {}

	local ShovelDeleteRequest = Remotes.get(Remotes.Names.ShovelDeleteRequest)
	local ShovelDeleteResult = Remotes.get(Remotes.Names.ShovelDeleteResult)

	local function sendResult(player, requestId, success, reason)
		if type(requestId) ~= "number" then return end
		RuntimeGuard.Run("ShovelService.FireResult", function()
			ShovelDeleteResult:FireClient(player, requestId, success, reason)
		end)
	end

	local function recordReject(player, reason, extra)
		local fields = TelemetryService.ForPlayer(player, extra or {})
		fields.reason = reason
		TelemetryService.Warn("shovel_delete_rejected", fields)
	end

	RuntimeGuard.Connect(Players.PlayerRemoving, "ShovelService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key == nil then return end
		lastFire[key] = nil
		locks[key] = nil
	end)

	RuntimeGuard.Connect(ShovelDeleteRequest.OnServerEvent, "ShovelService.DeleteRequest", function(player, requestId, target, toolGuid)
		if not consumeRateLimit(lastFire, player, rateSeconds) then
			sendResult(player, requestId, false, "rate-limited")
			return
		end
		local key = userKey(player)
		if key == nil then
			sendResult(player, requestId, false, "invalid-player")
			return
		end
		if locks[key] then
			sendResult(player, requestId, false, "busy")
			return
		end
		if not equippedShovel(player, toolGuid) then
			sendResult(player, requestId, false, "no-shovel")
			return
		end

		withPlayerLock(locks, player, function()
			local plot = PlotService.GetPlayerPlot(player)
			local profile = PlayerDataService.GetProfile(player)
			if not plot or not profile then
				sendResult(player, requestId, false, "no-plot")
				return
			end

			local feed = resolveFeedTarget(plot, target)
			if not feed or not isPlant(feed) then
				sendResult(player, requestId, false, "invalid-target")
				return
			end
			if not isPlayerNearInstance(player, feed, deleteDistance) then
				recordReject(player, "too-far", {
					target = feed,
					plot = plot,
				})
				sendResult(player, requestId, false, "too-far")
				return
			end

			local deletedName = feed.Name
			local feedType = feed:GetAttribute(State.Feed.Type)
			local placement = placementFromFeed(plot, feed)
			feed:Destroy()
			PetMotionService.RefreshPlotRoutes(plot)
			if type(snapshotProfileState) == "function" then
				local snapshotOk = snapshotProfileState(player, plot, profile)
				if not snapshotOk then
					restoreFeedPlacement(plot, player, placement)
					PetMotionService.RefreshPlotRoutes(plot)
					sendResult(player, requestId, false, "save-failed")
					return
				end
			end

			sendResult(player, requestId, true)
			NotificationService.Success(player, deletedName .. " deleted.")
			TelemetryService.Record("shovel_delete_succeeded", TelemetryService.ForPlayer(player, {
				feedType = feedType,
				plot = plot,
			}))
		end)
	end)
end

return ShovelService
