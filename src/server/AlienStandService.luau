-- Mr Alien's stand: the admin-toggled camp at Workspace.Map.MrAlienEvent.
--
-- Two jobs, both owned here because they are the same thing from the player's
-- side -- the stand only exists while the operator has it up:
--
-- 1. Presence. SetActive(true) clones ReplicatedStorage.Assets.AdminEvents.
--    MrAlienEvent into Workspace.Map (the template is authored in place, so the
--    clone keeps its CFrames) and stamps AlienStandActivatedAt for the client
--    entrance; SetActive(false) destroys it. It is idempotent and is reapplied
--    from every LiveEventCommandService reconcile, so a server that boots
--    mid-toggle raises the stand at startup -- same contract as the admin
--    party pad.
--
-- 2. Deposits. Players hold an Alien-mutated food and trigger the AlienCrate's
--    client-local prompt; the server validates (Alien mutation on the equipped
--    food, distance to the crate, stand actually up), consumes the tool
--    GUID-guarded (same double-spend guard as the Processor/Bee jar), and
--    advances the player's deposit counter in profile.Data.AlienStand. Filling
--    the crate auto-grants the tier's reward seed and advances the tier
--    (looping back to 1 after the last). If the reward grant is blocked
--    (inventory full) the deposits stay full and the grant retries on the next
--    deposit attempt.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AlienStand = require(Shared:WaitForChild("AlienStand"))
local Food = require(Shared:WaitForChild("Food"))
local Mutations = require(Shared:WaitForChild("Mutations"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local State = require(Shared:WaitForChild("State"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local NotificationService = require(script.Parent:WaitForChild("NotificationService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))
local PlotService = require(script.Parent:WaitForChild("PlotService"))
local SeedTools = require(script.Parent:WaitForChild("SeedTools"))
local TelemetryService = require(script.Parent:WaitForChild("TelemetryService"))

local AlienStandService = {}

local REQUEST_RATE_SECONDS = 0.1

local lastRequest = {}
local locks = {}
local started = false
local snapshotProfileState = nil
local isGameplayBlocked = nil

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

---------------------------------------------------------------------------
-- Presence
---------------------------------------------------------------------------

-- Only the HumanoidRootPart is anchored, matching the Beekeeper: the rest of
-- the rig hangs off its Motor6Ds so the idle track and the client's procedural
-- neck tilt still animate. The template is authored this way; re-applying it
-- here keeps a template regression from dropping Mr Alien through his platform.
local function prepareNpc(standFolder)
	local rig = standFolder:FindFirstChild(AlienStand.NpcName)
	if not (rig and rig:IsA("Model")) then
		warn("[AlienStandService] Missing " .. AlienStand.NpcName .. " rig in the stand template")
		return
	end
	local root = rig:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.Anchored = true
	else
		warn("[AlienStandService] " .. AlienStand.NpcName .. " has no HumanoidRootPart; rig may fall")
	end
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
	end
end

local function raise()
	local map = AlienStand.FindMapFolder()
	if not map then
		warn("[AlienStandService] Missing Workspace.Map; stand not raised")
		return false
	end
	local template = AlienStand.FindTemplate()
	if not template then
		warn("[AlienStandService] Missing ReplicatedStorage.Assets."
			.. AlienStand.AssetsFolderName .. "." .. AlienStand.TemplateName .. "; stand not raised")
		return false
	end

	local standFolder = template:Clone()
	prepareNpc(standFolder)
	-- Stamped before parenting so the attribute lands with the clone and no
	-- client can observe the stand without an entrance timestamp.
	standFolder:SetAttribute(State.AlienStand.ActivatedAt, Workspace:GetServerTimeNow())
	standFolder.Parent = map
	print("[AlienStandService] Alien stand raised")
	return true
end

local function lower()
	local standFolder = AlienStand.FindRuntimeFolder()
	if not standFolder then
		return false
	end
	standFolder:Destroy()
	print("[AlienStandService] Alien stand lowered")
	return true
end

-- Idempotent: safe to reapply on every control-plane reconcile. Returns true
-- when this call changed the world.
function AlienStandService.SetActive(active)
	active = active == true and AlienStand.Enabled
	local standFolder = AlienStand.FindRuntimeFolder()
	if active then
		if standFolder then
			return false
		end
		return raise()
	end
	if not standFolder then
		return false
	end
	return lower()
end

function AlienStandService.IsActive()
	return AlienStand.FindRuntimeFolder() ~= nil
end

---------------------------------------------------------------------------
-- Deposits
---------------------------------------------------------------------------

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
	return (root.Position - cratePosition).Magnitude <= AlienStand.MaxDepositDistance
end

local function ensureAlienStandData(profile)
	local data = profile.Data.AlienStand
	if type(data) ~= "table" then
		data = { Tier = 1, Deposits = 0 }
		profile.Data.AlienStand = data
	end
	data.Tier = AlienStand.NormalizeTier(data.Tier)
	data.Deposits = math.max(math.floor(tonumber(data.Deposits) or 0), 0)
	return data
end

local function crateFilled(data)
	return data.Deposits >= (AlienStand.RequiredFor(data.Tier) or 0)
end

-- Grants the current tier's reward seed, then resets deposits and advances the
-- tier. Returns the granted seedId, or nil when the grant was blocked (the
-- deposits are left intact so the completion retries on the next deposit).
local function tryCompleteTier(player, profile, data)
	local rewardSeedId = AlienStand.TierConfig(data.Tier).rewardSeedId
	local prepared = SeedTools.PrepareGrant(rewardSeedId, 1)
	if not prepared then
		warn("[AlienStandService] Missing reward seed template " .. tostring(rewardSeedId))
		return nil
	end
	local granted = SeedTools.ApplyPrepared(player, profile, prepared)
	if not granted then
		NotificationService.Error(player, "Make room in your inventory for your reward!")
		return nil
	end
	data.Deposits = 0
	data.Tier = AlienStand.NextTier(data.Tier)
	NotificationService.Success(player, string.format("Crate filled! You received a %s!", Seeds.DisplayNameFor(rewardSeedId)))
	return rewardSeedId
end

function AlienStandService.Start(config)
	if started then
		return
	end
	if not AlienStand.Enabled then
		return
	end
	started = true
	config = config or {}
	snapshotProfileState = config.snapshotProfileState
	isGameplayBlocked = config.isGameplayBlocked

	assert(type(snapshotProfileState) == "function", "AlienStandService.Start requires snapshotProfileState")

	local requestRemote = Remotes.get(Remotes.Names.AlienDepositRequest)
	local resultRemote = Remotes.get(Remotes.Names.AlienDepositResult)

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
		TelemetryService.Record("alienstand_deposit_rejected", TelemetryService.ForPlayer(player, {
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

		-- No stand, no sink: unlike the always-on Bee jar, the crate only
		-- exists while an operator has Mr Alien up.
		local crate = AlienStand.FindCrate()
		if not crate then
			sendResult(player, requestId, false, "no-stand")
			return
		end
		if not isNearCrate(player, crate) then
			reject(player, requestId, "too-far")
			return
		end

		local data = ensureAlienStandData(profile)
		local required = AlienStand.RequiredFor(data.Tier) or 0

		-- A blocked reward grant leaves the crate full; retry it before
		-- treating this deposit as overflow.
		if data.Deposits >= required then
			local rewardSeedId = tryCompleteTier(player, profile, data)
			if rewardSeedId then
				snapshotProfileState(player, PlotService.GetPlayerPlot(player), profile)
				sendResult(player, requestId, true, "reward", { rewardSeedId = rewardSeedId, tier = data.Tier })
				return
			end
			reject(player, requestId, "crate-full", "The crate is already full!")
			return
		end

		local food = Food.GetEquipped(player, nil)
		if not food then
			reject(player, requestId, "no-food", "Hold an Alien food to deposit it!")
			return
		end
		if not Mutations.Contains(Food.MutationIdsOf(food), AlienStand.MutationId) then
			reject(player, requestId, "wrong-mutation", "The crate only takes Alien food!")
			return
		end

		local foodGuid = ToolIdentity.EnsureGuid(food)
		if not ToolIdentity.DestroyIfGuidMatches(food, foodGuid) then
			reject(player, requestId, "consume-failed")
			return
		end

		data.Deposits += 1

		local rewardSeedId = nil
		if crateFilled(data) then
			rewardSeedId = tryCompleteTier(player, profile, data)
		end

		snapshotProfileState(player, PlotService.GetPlayerPlot(player), profile)
		sendResult(player, requestId, true, "deposited", {
			count = data.Deposits,
			required = AlienStand.RequiredFor(data.Tier) or required,
			tier = data.Tier,
			rewardSeedId = rewardSeedId,
		})
	end

	RuntimeGuard.Connect(requestRemote.OnServerEvent, "AlienStandService.DepositRequest", function(player, requestId)
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
		RuntimeGuard.Run("AlienStandService.HandleDeposit", handleDeposit, player, requestId)
		locks[key] = nil
	end)

	RuntimeGuard.Connect(Players.PlayerRemoving, "AlienStandService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key ~= nil then
			lastRequest[key] = nil
			locks[key] = nil
		end
	end)
end

return AlienStandService
