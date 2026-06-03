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

local function equippedShovel(player)
	local character = player.Character
	local tool = character and character:FindFirstChildWhichIsA("Tool")
	return Shovel.IsTool(tool)
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

	Players.PlayerRemoving:Connect(function(player)
		local key = userKey(player)
		if key == nil then return end
		lastFire[key] = nil
		locks[key] = nil
	end)

	ShovelDeleteRequest.OnServerEvent:Connect(function(player, requestId, target)
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
		if not equippedShovel(player) then
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
			feed:Destroy()
			PetMotionService.RefreshPlotRoutes(plot)
			if type(snapshotProfileState) == "function" then
				snapshotProfileState(player, plot, profile)
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
