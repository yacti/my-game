local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local FeedGrowthService = require(Server:WaitForChild("FeedGrowthService"))
local FeedMachines = require(Server:WaitForChild("feedMachines"))
local FeedMachineTools = require(Server:WaitForChild("FeedMachineTools"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local OnboardingService = require(Server:WaitForChild("OnboardingService"))
local PetMotionService = require(Server:WaitForChild("PetMotionService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService = require(Server:WaitForChild("PlotService"))
local SeedTools = require(Server:WaitForChild("SeedTools"))
local TelemetryService = require(Server:WaitForChild("TelemetryService"))
local ToolGrantService = require(Server:WaitForChild("ToolGrantService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local State = require(Shared:WaitForChild("State"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local FeedPlacementService = {}

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
	RuntimeGuard.Run("FeedPlacementService.Handler", callback)
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

function FeedPlacementService.Start(config)
	config = config or {}
	local snapshotProfileState = config.snapshotProfileState
	local rateSeconds = tonumber(config.rateSeconds) or DEFAULT_RATE_SECONDS
	local placeDistance = tonumber(config.placeDistance) or DEFAULT_PLACE_DISTANCE
	local lastFire = {}
	local locks = {}

	local PlaceFeedMachine = Remotes.get(Remotes.Names.PlaceFeedMachine)
	local PlaceFeedMachineResult = Remotes.get(Remotes.Names.PlaceFeedMachineResult)

	local function sendPlaceResult(player, requestId, success, reason)
		if type(requestId) ~= "number" then return end
		RuntimeGuard.Run("FeedPlacementService.FireResult", function()
			PlaceFeedMachineResult:FireClient(player, requestId, success, reason)
		end)
	end

	local function recordPlacementReject(player, reason, extra)
		local fields = TelemetryService.ForPlayer(player, extra or {})
		fields.reason = reason
		TelemetryService.Warn("feed_placement_rejected", fields)
	end

	local function restoreConsumedTool(player, placingSeed, seedId, feedType)
		local backpack = player and player:FindFirstChildOfClass("Backpack")
		if not backpack then
			return false
		end
		local replacement = placingSeed and SeedTools.MakeSeedTool(seedId) or FeedMachineTools.MakeFeedTool(feedType)
		if not replacement then
			return false
		end
		return ToolGrantService.GrantTool(player, replacement)
	end

	RuntimeGuard.Connect(Players.PlayerRemoving, "FeedPlacementService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key == nil then return end
		lastFire[key] = nil
		locks[key] = nil
	end)

	RuntimeGuard.Connect(PlaceFeedMachine.OnServerEvent, "FeedPlacementService.PlaceFeedMachine", function(player, requestId, cframe, toolGuid)
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
			local character = player.Character
			if not character then
				recordPlacementReject(player, "no-character")
				sendPlaceResult(player, requestId, false, "no-character")
				return
			end
			local profile = PlayerDataService.GetProfile(player)
			if not profile then
				sendPlaceResult(player, requestId, false, "no-profile")
				return
			end
			local tool = ToolIdentity.FindEquippedByGuid(player, toolGuid, function(item)
				return SeedTools.IsSeedTool(item) or FeedMachineTools.IsFeedTool(item)
			end)
			if not tool then
				sendPlaceResult(player, requestId, false, "no-feed-tool")
				return
			end
			local seedId = nil
			local placingSeed = SeedTools.IsSeedTool(tool)
			local feedType = nil
			if placingSeed then
				seedId = SeedTools.SeedIdOf(tool)
				feedType = seedId and Seeds.FeedTypeFor(seedId) or nil
			elseif FeedMachineTools.IsFeedTool(tool) then
				feedType = tool:GetAttribute(State.Feed.Type)
			else
				sendPlaceResult(player, requestId, false, "no-feed-tool")
				return
			end

			if type(feedType) ~= "string" or feedType == "" then
				sendPlaceResult(player, requestId, false, "no-feed-tool")
				return
			end

			local floor = PlotService.GetFloor(plot)
			if not floor then
				sendPlaceResult(player, requestId, false, "no-floor")
				return
			end

			local template = FeedMachines.GetTemplate(feedType)
			if not template then
				sendPlaceResult(player, requestId, false, "no-template")
				return
			end

			-- Bounds check + grid snap + rotation snap all in the floor's local
			-- frame, so machines align to the possibly rotated plot axes.
			local localCF = floor.CFrame:ToObjectSpace(cframe)
			if math.abs(localCF.X) > floor.Size.X / 2 or
			   math.abs(localCF.Z) > floor.Size.Z / 2 then
				sendPlaceResult(player, requestId, false, "out-of-bounds")
				return
			end
			local snappedLX  = math.round(localCF.X)
			local snappedLZ  = math.round(localCF.Z)
			local _, lry, _  = localCF:ToEulerAnglesXYZ()
			local snappedLRY = math.round(lry / (math.pi / 2)) * (math.pi / 2)
			local snappedWorldPosition = floor.CFrame:PointToWorldSpace(Vector3.new(snappedLX, 0, snappedLZ))
			if not isPlayerNearPosition(player, snappedWorldPosition, placeDistance) then
				recordPlacementReject(player, "too-far", {
					feedType = feedType,
					plot = plot,
					position = snappedWorldPosition,
				})
				sendPlaceResult(player, requestId, false, "too-far")
				return
			end
			if not PlotService.FeedPlacementFitsOnFloor(plot, feedType, snappedLX, snappedLZ, snappedLRY) then
				sendPlaceResult(player, requestId, false, "out-of-bounds")
				return
			end
			if PlotService.FeedPlacementOverlaps(plot, feedType, snappedLX, snappedLZ, snappedLRY) then
				sendPlaceResult(player, requestId, false, "overlap")
				return
			end

			local feedPart
			local placeCode
			if placingSeed then
				feedPart, placeCode = FeedGrowthService.PlaceSeed(plot, player, seedId, snappedLX, snappedLZ, snappedLRY)
			else
				feedPart = PlotService.PlaceFeed(plot, feedType, snappedLX, snappedLZ, snappedLRY)
			end
			if not feedPart then
				sendPlaceResult(player, requestId, false, placeCode or "place-failed")
				return
			end

			if not placingSeed then
				local setupSucceeded, setupCode = FeedMachines.Setup(feedPart, plot, player)
				if not setupSucceeded then
					feedPart:Destroy()
					sendPlaceResult(player, requestId, false, setupCode or "setup-failed")
					return
				end
			end

			if not ToolIdentity.DestroyIfGuidMatches(tool, toolGuid) then
				feedPart:Destroy()
				sendPlaceResult(player, requestId, false, "no-feed-tool")
				return
			end
			PetMotionService.RefreshPlotRoutes(plot)
			if profile and type(snapshotProfileState) == "function" then
				local snapshotOk = snapshotProfileState(player, plot, profile)
				if not snapshotOk then
					feedPart:Destroy()
					PetMotionService.RefreshPlotRoutes(plot)
					restoreConsumedTool(player, placingSeed, seedId, feedType)
					sendPlaceResult(player, requestId, false, "save-failed")
					return
				end
			end
			if placingSeed then
				local advanced = OnboardingService.OnSeedPlaced(player, profile, plot, feedPart, seedId, feedType)
				if advanced and type(snapshotProfileState) == "function" then
					RuntimeGuard.Run("FeedPlacementService.SnapshotAfterOnboarding", snapshotProfileState, player, plot, profile)
				end
			end
			sendPlaceResult(player, requestId, true)
			TelemetryService.Record("feed_placement_succeeded", TelemetryService.ForPlayer(player, {
				feedType = feedType,
				plot = plot,
				seedId = seedId,
			}))
			NotificationService.Success(player, placingSeed and "Seed planted!" or (feedPart.Name .. " placed!"))
		end)
	end)
end

return FeedPlacementService
