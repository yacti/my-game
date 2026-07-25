-- Bee event Jar deposits. Players hold a Pollinated food and trigger the
-- Jar's client-local prompt; the server validates (Pollinated mutation on the
-- equipped food, distance to the Jar), consumes the tool GUID-guarded (same
-- double-spend guard as the Processor/StormChaser), and advances the player's
-- single deposit counter in profile.Data.BeeEvent. Filling the jar
-- auto-grants the tier's reward seed and advances the tier (looping back to 1
-- after the last tier). If the reward grant is blocked (inventory full) the
-- deposits stay full and the grant retries on the player's next deposit
-- attempt. Deposits are valid between events -- Pollinated food is durable
-- inventory and the Jar is an always-on meta sink.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BeeEvent = require(Shared:WaitForChild("BeeEvent"))
local Food = require(Shared:WaitForChild("Food"))
local Mutations = require(Shared:WaitForChild("Mutations"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local NotificationService = require(script.Parent:WaitForChild("NotificationService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))
local PlotService = require(script.Parent:WaitForChild("PlotService"))
local SeedTools = require(script.Parent:WaitForChild("SeedTools"))
local TelemetryService = require(script.Parent:WaitForChild("TelemetryService"))

local BeeEventService = {}

local REQUEST_RATE_SECONDS = 0.1

local lastRequest = {}
local locks = {}

local function userKey(player)
	return player and player.UserId or nil
end

local function isValidRequestId(value)
	return type(value) == "number" and value == math.floor(value) and value > 0
end

local function consumeRateLimit(player)
	local key = userKey(player)
	if key == nil then
		return false
	end
	local now = os.clock()
	local previous = lastRequest[key] or 0
	if now - previous < REQUEST_RATE_SECONDS then
		return false
	end
	lastRequest[key] = now
	return true
end

local function isNearJar(player, jar)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local ok, jarPosition = pcall(function()
		return jar:GetPivot().Position
	end)
	if not ok then
		return false
	end
	return (root.Position - jarPosition).Magnitude <= BeeEvent.MaxDepositDistance
end

local function ensureBeeEventData(profile)
	local data = profile.Data.BeeEvent
	if type(data) ~= "table" then
		data = { Tier = 1, Deposits = 0 }
		profile.Data.BeeEvent = data
	end
	data.Tier = BeeEvent.NormalizeTier(data.Tier)
	data.Deposits = math.max(math.floor(tonumber(data.Deposits) or 0), 0)
	return data
end

local function jarFilled(data)
	return data.Deposits >= (BeeEvent.RequiredFor(data.Tier) or 0)
end

-- Grants the current tier's reward seed, then resets deposits and advances the
-- tier. Returns the granted seedId, or nil when the grant was blocked (the
-- deposits are left intact so the completion retries on the next deposit).
local function tryCompleteTier(player, profile, data)
	local rewardSeedId = BeeEvent.TierConfig(data.Tier).rewardSeedId
	local prepared = SeedTools.PrepareGrant(rewardSeedId, 1)
	if not prepared then
		warn("[BeeEventService] Missing reward seed template " .. tostring(rewardSeedId))
		return nil
	end
	local granted = SeedTools.ApplyPrepared(player, profile, prepared)
	if not granted then
		NotificationService.Error(player, "Make room in your inventory for your reward!")
		return nil
	end
	data.Deposits = 0
	data.Tier = BeeEvent.NextTier(data.Tier)
	NotificationService.Success(player, string.format("Jar filled! You received a %s!", Seeds.DisplayNameFor(rewardSeedId)))
	return rewardSeedId
end

function BeeEventService.Start(config)
	if not BeeEvent.Enabled then
		return
	end
	config = config or {}
	local snapshotProfileState = config.snapshotProfileState
	local isGameplayBlocked = config.isGameplayBlocked

	assert(type(snapshotProfileState) == "function", "BeeEventService.Start requires snapshotProfileState")

	local requestRemote = Remotes.get(Remotes.Names.BeeDepositRequest)
	local resultRemote = Remotes.get(Remotes.Names.BeeDepositResult)

	local function sendResult(player, requestId, success, code, extra)
		local payload = {
			requestId = requestId,
			success = success == true,
			code = code,
		}
		if type(extra) == "table" then
			for key, value in pairs(extra) do
				payload[key] = value
			end
		end
		resultRemote:FireClient(player, payload)
	end

	local function reject(player, requestId, code, message)
		if message then
			NotificationService.Error(player, message)
		end
		TelemetryService.Record("beeevent_deposit_rejected", TelemetryService.ForPlayer(player, {
			reason = code,
		}))
		sendResult(player, requestId, false, code)
	end

	local function handleDeposit(player, requestId)
		if type(isGameplayBlocked) == "function" and isGameplayBlocked(player) then
			sendResult(player, requestId, false, "blocked")
			return
		end
		local profile = PlayerDataService.GetProfile(player)
		if not profile then
			sendResult(player, requestId, false, "no-profile")
			return
		end

		local jar = BeeEvent.FindJar()
		if not jar then
			warn("[BeeEventService] Missing Jar under Workspace.Map." .. BeeEvent.MapFolderName .. "." .. BeeEvent.ActiveFolderName)
			sendResult(player, requestId, false, "no-jar")
			return
		end
		if not isNearJar(player, jar) then
			reject(player, requestId, "too-far")
			return
		end

		local data = ensureBeeEventData(profile)
		local required = BeeEvent.RequiredFor(data.Tier) or 0

		-- A blocked reward grant leaves the jar full; retry it before
		-- treating this deposit as overflow.
		if data.Deposits >= required then
			local rewardSeedId = tryCompleteTier(player, profile, data)
			if rewardSeedId then
				snapshotProfileState(player, PlotService.GetPlayerPlot(player), profile)
				sendResult(player, requestId, true, "reward", { rewardSeedId = rewardSeedId, tier = data.Tier })
				return
			end
			reject(player, requestId, "jar-full", "The jar is already full!")
			return
		end

		local food = Food.GetEquipped(player, nil)
		if not food then
			reject(player, requestId, "no-food", "Hold a Pollinated food to deposit it!")
			return
		end
		if not Mutations.Contains(Food.MutationIdsOf(food), BeeEvent.MutationId) then
			reject(player, requestId, "wrong-mutation", "The jar only takes Pollinated food!")
			return
		end

		local foodGuid = ToolIdentity.EnsureGuid(food)
		if not ToolIdentity.DestroyIfGuidMatches(food, foodGuid) then
			reject(player, requestId, "consume-failed")
			return
		end

		data.Deposits += 1

		local rewardSeedId = nil
		if jarFilled(data) then
			rewardSeedId = tryCompleteTier(player, profile, data)
		end

		snapshotProfileState(player, PlotService.GetPlayerPlot(player), profile)
		sendResult(player, requestId, true, "deposited", {
			count = data.Deposits,
			required = BeeEvent.RequiredFor(data.Tier) or required,
			tier = data.Tier,
			rewardSeedId = rewardSeedId,
		})
	end

	RuntimeGuard.Connect(requestRemote.OnServerEvent, "BeeEventService.DepositRequest", function(player, requestId)
		if not isValidRequestId(requestId) then
			return
		end
		if not consumeRateLimit(player) then
			return
		end
		local key = userKey(player)
		if key == nil or locks[key] then
			return
		end
		locks[key] = true
		RuntimeGuard.Run("BeeEventService.HandleDeposit", handleDeposit, player, requestId)
		locks[key] = nil
	end)

	RuntimeGuard.Connect(Players.PlayerRemoving, "BeeEventService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key ~= nil then
			lastRequest[key] = nil
			locks[key] = nil
		end
	end)
end

return BeeEventService
