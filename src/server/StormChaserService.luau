-- StormChaser crate deposits. Players hold a mutated fruit and trigger the
-- crate's client-local prompt; the server validates (matching mutation on the
-- equipped food, distance to the crate), consumes the tool GUID-guarded (same
-- double-spend guard as the Processor), and advances the player's per-mutation
-- deposit progress in profile.Data.StormChaser. Filling all three crates
-- auto-grants the tier's reward seed and advances the tier (looping back to 1
-- after the last tier). If the reward grant is blocked (inventory full) the
-- deposits stay full and the grant retries on the player's next deposit
-- attempt.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
local Mutations = require(Shared:WaitForChild("Mutations"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local StormChaser = require(Shared:WaitForChild("StormChaser"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local NotificationService = require(script.Parent:WaitForChild("NotificationService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))
local PlotService = require(script.Parent:WaitForChild("PlotService"))
local SeedTools = require(script.Parent:WaitForChild("SeedTools"))
local TelemetryService = require(script.Parent:WaitForChild("TelemetryService"))

local StormChaserService = {}

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

local function isNearCrate(player, crate)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local ok, cratePosition = pcall(function()
		return crate:GetPivot().Position
	end)
	if not ok then
		return false
	end
	return (root.Position - cratePosition).Magnitude <= StormChaser.MaxDepositDistance
end

local function ensureStormChaserData(profile)
	local data = profile.Data.StormChaser
	if type(data) ~= "table" then
		data = { Tier = 1, Deposits = {} }
		profile.Data.StormChaser = data
	end
	data.Tier = StormChaser.NormalizeTier(data.Tier)
	if type(data.Deposits) ~= "table" then
		data.Deposits = {}
	end
	return data
end

local function allCratesFilled(data)
	for _, mutationId in ipairs(StormChaser.CrateMutationIds) do
		local required = StormChaser.RequiredFor(data.Tier, mutationId) or 0
		if (data.Deposits[mutationId] or 0) < required then
			return false
		end
	end
	return true
end

-- Grants the current tier's reward seed, then resets deposits and advances the
-- tier. Returns the granted seedId, or nil when the grant was blocked (the
-- deposits are left intact so the completion retries on the next deposit).
local function tryCompleteTier(player, profile, data)
	local rewardSeedId = StormChaser.TierConfig(data.Tier).rewardSeedId
	local prepared = SeedTools.PrepareGrant(rewardSeedId, 1)
	if not prepared then
		warn("[StormChaserService] Missing reward seed template " .. tostring(rewardSeedId))
		return nil
	end
	local granted = SeedTools.ApplyPrepared(player, profile, prepared)
	if not granted then
		NotificationService.Error(player, "Make room in your inventory for your reward!")
		return nil
	end
	data.Deposits = {}
	data.Tier = StormChaser.NextTier(data.Tier)
	NotificationService.Success(player, string.format("Crates filled! You received a %s!", Seeds.DisplayNameFor(rewardSeedId)))
	return rewardSeedId
end

function StormChaserService.Start(config)
	config = config or {}
	local snapshotProfileState = config.snapshotProfileState
	local isGameplayBlocked = config.isGameplayBlocked

	assert(type(snapshotProfileState) == "function", "StormChaserService.Start requires snapshotProfileState")

	local requestRemote = Remotes.get(Remotes.Names.StormChaserDepositRequest)
	local resultRemote = Remotes.get(Remotes.Names.StormChaserDepositResult)

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
		TelemetryService.Record("stormchaser_deposit_rejected", TelemetryService.ForPlayer(player, {
			reason = code,
		}))
		sendResult(player, requestId, false, code)
	end

	local function handleDeposit(player, requestId, mutationId)
		if type(mutationId) ~= "string" or StormChaser.CrateNames[mutationId] == nil then
			return
		end
		if type(isGameplayBlocked) == "function" and isGameplayBlocked(player) then
			sendResult(player, requestId, false, "blocked")
			return
		end
		local profile = PlayerDataService.GetProfile(player)
		if not profile then
			sendResult(player, requestId, false, "no-profile")
			return
		end

		local activeFolder = StormChaser.FindActiveFolder()
		local crate = StormChaser.FindCrate(activeFolder, mutationId)
		if not crate then
			warn("[StormChaserService] Missing crate for mutation " .. mutationId)
			sendResult(player, requestId, false, "no-crate")
			return
		end
		if not isNearCrate(player, crate) then
			reject(player, requestId, "too-far")
			return
		end

		local data = ensureStormChaserData(profile)
		local required = StormChaser.RequiredFor(data.Tier, mutationId) or 0
		local count = data.Deposits[mutationId] or 0

		-- A blocked reward grant leaves every crate full; retry it before
		-- treating this crate as full.
		if count >= required then
			if allCratesFilled(data) then
				local rewardSeedId = tryCompleteTier(player, profile, data)
				if rewardSeedId then
					snapshotProfileState(player, PlotService.GetPlayerPlot(player), profile)
					sendResult(player, requestId, true, "reward", { rewardSeedId = rewardSeedId, tier = data.Tier })
					return
				end
			end
			reject(player, requestId, "crate-full", "This crate is already full!")
			return
		end

		local food = Food.GetEquipped(player, nil)
		if not food then
			reject(player, requestId, "no-food", "Hold a mutated fruit to deposit it!")
			return
		end
		if not Mutations.Contains(Food.MutationIdsOf(food), mutationId) then
			reject(player, requestId, "wrong-mutation", string.format("This crate needs %s food!", mutationId))
			return
		end

		local foodGuid = ToolIdentity.EnsureGuid(food)
		if not ToolIdentity.DestroyIfGuidMatches(food, foodGuid) then
			reject(player, requestId, "consume-failed")
			return
		end

		count += 1
		data.Deposits[mutationId] = count

		local rewardSeedId = nil
		if allCratesFilled(data) then
			rewardSeedId = tryCompleteTier(player, profile, data)
		end

		snapshotProfileState(player, PlotService.GetPlayerPlot(player), profile)
		sendResult(player, requestId, true, "deposited", {
			mutationId = mutationId,
			count = count,
			required = required,
			tier = data.Tier,
			rewardSeedId = rewardSeedId,
		})
	end

	RuntimeGuard.Connect(requestRemote.OnServerEvent, "StormChaserService.DepositRequest", function(player, requestId, mutationId)
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
		RuntimeGuard.Run("StormChaserService.HandleDeposit", handleDeposit, player, requestId, mutationId)
		locks[key] = nil
	end)

	RuntimeGuard.Connect(Players.PlayerRemoving, "StormChaserService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key ~= nil then
			lastRequest[key] = nil
			locks[key] = nil
		end
	end)
end

return StormChaserService
