local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local FeedMachines = require(Server:WaitForChild("feedMachines"))
local FeedMachineTools = require(Server:WaitForChild("FeedMachineTools"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local PetMotionService = require(Server:WaitForChild("PetMotionService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService = require(Server:WaitForChild("PlotService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local State = require(Shared:WaitForChild("State"))

local FeedPlacementService = {}

local DEFAULT_RATE_SECONDS = 0.25

local function consumeRateLimit(map, player, interval)
	local now = os.clock()
	local previous = map[player] or 0
	if now - previous < interval then return false end
	map[player] = now
	return true
end

local function withPlayerLock(map, player, callback)
	if map[player] then return end
	map[player] = true
	local ok, err = pcall(callback)
	map[player] = nil
	if not ok then
		warn(err)
	end
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

function FeedPlacementService.Start(config)
	config = config or {}
	local snapshotProfileState = config.snapshotProfileState
	local rateSeconds = tonumber(config.rateSeconds) or DEFAULT_RATE_SECONDS
	local lastFire = {}
	local locks = {}

	local PlaceFeedMachine = Remotes.get(Remotes.Names.PlaceFeedMachine)
	local PlaceFeedMachineResult = Remotes.get(Remotes.Names.PlaceFeedMachineResult)

	local function sendPlaceResult(player, requestId, success, reason)
		if type(requestId) ~= "number" then return end
		PlaceFeedMachineResult:FireClient(player, requestId, success, reason)
	end

	PlaceFeedMachine.OnServerEvent:Connect(function(player, requestId, cframe)
		if not isValidCFrame(cframe) then
			sendPlaceResult(player, requestId, false, "invalid-cframe")
			return
		end
		if not consumeRateLimit(lastFire, player, rateSeconds) then
			sendPlaceResult(player, requestId, false, "rate-limited")
			return
		end
		local plot = PlotService.GetPlayerPlot(player)
		if not plot then
			sendPlaceResult(player, requestId, false, "no-plot")
			return
		end
		if locks[player] then
			sendPlaceResult(player, requestId, false, "busy")
			return
		end

		withPlayerLock(locks, player, function()
			local character = player.Character
			if not character then
				sendPlaceResult(player, requestId, false, "no-character")
				return
			end
			local tool = character:FindFirstChildWhichIsA("Tool")
			if not FeedMachineTools.IsFeedTool(tool) then
				sendPlaceResult(player, requestId, false, "no-feed-tool")
				return
			end

			local feedType = tool:GetAttribute(State.Feed.Type)
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
			if not PlotService.FeedPlacementFitsOnFloor(plot, feedType, snappedLX, snappedLZ, snappedLRY) then
				sendPlaceResult(player, requestId, false, "out-of-bounds")
				return
			end
			if PlotService.FeedPlacementOverlaps(plot, feedType, snappedLX, snappedLZ, snappedLRY) then
				sendPlaceResult(player, requestId, false, "overlap")
				return
			end

			local feedPart = PlotService.PlaceFeed(plot, feedType, snappedLX, snappedLZ, snappedLRY)
			if not feedPart then
				sendPlaceResult(player, requestId, false, "place-failed")
				return
			end

			tool:Destroy()
			FeedMachines.Setup(feedPart, plot, player)
			PetMotionService.RefreshPlotRoutes(plot)
			local profile = PlayerDataService.GetProfile(player)
			if profile and type(snapshotProfileState) == "function" then
				snapshotProfileState(player, plot, profile)
			end
			sendPlaceResult(player, requestId, true)
			NotificationService.Success(player, feedPart.Name .. " placed!")
		end)
	end)
end

return FeedPlacementService
