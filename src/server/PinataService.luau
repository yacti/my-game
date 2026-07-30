-- Admin-spawned pinatas: server authority for spawning, HP, the damage ledger,
-- the reward split, physical drops and every grant.
--
-- Control plane: LiveEventCommandService.SpawnPinata / ClearPinatas broadcast a
-- one-shot delta on the LiveEvents_v1 topic and call Spawn/ClearAll here on
-- every server. Nothing about a pinata is durable -- a server that misses the
-- broadcast simply has no pinata, and nothing survives a restart. Spawn and
-- ClearAll are public so they can also be driven straight from the server
-- command bar, which is the only way to test in Studio without API Services:
--
--   require(game.ServerScriptService.Server.PinataService).Spawn("Default")
--   require(game.ServerScriptService.Server.PinataService).ClearAll()
--
-- Client relationship: the server writes State.Pinata.* attributes onto the
-- replicated Model and onto each dropped reward part; PinataController renders
-- from those. There is exactly one client->server remote (PinataSwingRequest)
-- and it carries no arguments -- the server resolves the nearest pinata within
-- reach itself, so there is no forgeable target field.
--
-- No pinata reward mints a Tool (they are grow skips, currency and durian
-- tickets), so the Inventory soft cap can never block a payout. If a future
-- reward drops a seed or food tool, it must go through ToolGrantService and
-- handle "inventory-full" -- see AGENTS.md.
--
-- PolicyService.ArePaidRandomItemsRestricted deliberately does NOT apply: these
-- are free admin-granted rewards, not paid random items.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Server = script.Parent
local CurrencyService = require(Server:WaitForChild("CurrencyService"))
local EventEligibility = require(Server:WaitForChild("EventEligibility"))
local GrowSkipService = require(Server:WaitForChild("GrowSkipService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local PetIncomeService = require(Server:WaitForChild("PetIncomeService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local TelemetryService = require(Server:WaitForChild("TelemetryService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Pinata = require(Shared:WaitForChild("Pinata"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))

local PinataService = {}

local SWEEP_INTERVAL = 0.25
local STICK_SWEEP_INTERVAL = 0.5
-- Coalesce HP writes: twenty simultaneous hitters must not produce forty
-- attribute replications a second on one instance.
local HP_PUBLISH_INTERVAL = 0.1
local BREAK_LINGER_SECONDS = 0.6
local SPAWN_TOAST_LIFETIME = 5
-- Where the stick's Handle sits relative to the character's right hand, and the
-- only tuning knob for the hold pose.
--
-- The bat extends along the Handle's local +Y (6.97 studs up, 1.35 down), and
-- with no rotation the Handle inherits the hand's orientation -- whose UpVector
-- is very nearly world-up. That stands an 8.3-stud bat vertically out of a fist
-- held beside the torso, so it clips straight through the head. The rotation
-- tilts it outward (character's right) and back, resting it over the shoulder
-- and clear of the head.
local STICK_GRIP_OFFSET = CFrame.new(0, -0.4, 0) * CFrame.Angles(math.rad(18), 0, math.rad(-30))

local swingRemote = Remotes.get(Remotes.Names.PinataSwingRequest)

-- Live pinatas keyed by id: { id, variantId, config, model, primary, spawnPart,
-- hp, dirtyHp, lastPublish, dropAt, expiresAt, ledger = { [userId] = damage },
-- broken }
local pinatas = {}
local nextPinataId = 0
-- Drop records keyed by instance: { part, ownerId, rewardId, payout, armedAt, expiresAt }
local drops = {}
-- Welded sticks and swing cooldowns, both keyed by UserId.
local sticks = {}
local swingCooldown = {}
local started = false
local sweepConnection = nil
local stickConnection = nil
local runtimeFolder = nil
local dropsFolder = nil
local isGameplayBlocked = nil

local function userKey(player)
	local userId = player and tonumber(player.UserId)
	if type(userId) ~= "number" or userId ~= userId or userId % 1 ~= 0 or userId == 0 then
		return nil
	end
	return userId
end

local function serverNow()
	return Workspace:GetServerTimeNow()
end

local function blocked(player)
	if type(isGameplayBlocked) ~= "function" then
		return false
	end
	local ok, result = pcall(isGameplayBlocked, player)
	return ok and result == true
end

local function rootPart(player)
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root or nil
end

local function ensureFolder(name, cache)
	if cache and cache.Parent == Workspace then
		return cache
	end
	local existing = Workspace:FindFirstChild(name)
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = Workspace
	return folder
end

local function runtime()
	runtimeFolder = ensureFolder(Pinata.RuntimeFolderName, runtimeFolder)
	return runtimeFolder
end

local function dropsRoot()
	dropsFolder = ensureFolder(Pinata.DropsFolderName, dropsFolder)
	return dropsFolder
end

local function miscFolder()
	return Assets.Find(Assets.Names.Misc)
end

-- ── Spawning ──────────────────────────────────────────────────────────────────

local function occupiedSpawnParts()
	local occupied = {}
	for _, record in pairs(pinatas) do
		if record.spawnPart then
			occupied[record.spawnPart] = true
		end
	end
	return occupied
end

local function pickFreeSpawn()
	local folder = Pinata.FindSpawnFolder()
	if not folder then
		return nil, "no-spawn-folder"
	end
	local occupied = occupiedSpawnParts()
	local free = {}
	-- SpawnMarkers excludes the PinataFloor slab that shares this folder.
	for _, marker in ipairs(Pinata.SpawnMarkers()) do
		if not occupied[marker] then
			free[#free + 1] = marker
		end
	end
	if #free == 0 then
		return nil, "no-free-slot"
	end
	return free[Random.new():NextInteger(1, #free)], "ok"
end

local function prepareSpawnedModel(model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			-- Templates ship unanchored and collidable. A 9-to-17 stud model
			-- left to physics would roll off its marker and break both the
			-- client's pivot animation and the server's distance checks.
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		elseif descendant:IsA("ParticleEmitter") then
			-- Authored emitters are the break burst; keep them off until then
			-- rather than running eight permanent emitters on the map.
			descendant.Enabled = false
		end
	end
end

local function setParticles(model, enabled)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = enabled
		end
	end
end

local function announceSpawn(config)
	-- DisplayName carries the variant ("Pinata" / "Golden Pinata"), so one format
	-- string covers both and the Golden toast animates via its ToastKind.
	local text = string.format("A %s has appeared!", config.DisplayName)
	for _, player in ipairs(Players:GetPlayers()) do
		if EventEligibility.IsEligible(player) then
			RuntimeGuard.Run("PinataService.AnnounceSpawn", function()
				NotificationService.Notify(player, {
					kind = config.ToastKind or NotificationConfig.Kinds.Mythical,
					text = text,
					lifetime = SPAWN_TOAST_LIFETIME,
				})
			end)
		end
	end
end

-- Spawns one pinata at a random free spawn part. Returns (true, pinataId) or
-- (false, code) so the admin panel can toast the failure.
function PinataService.Spawn(variantId)
	local config = Pinata.VariantConfig(variantId)
	if not config then
		return false, "unknown-pinata-variant"
	end
	local misc = miscFolder()
	local template = misc and misc:FindFirstChild(config.ModelName)
	if not (template and template:IsA("Model")) then
		warn("[PinataService] Missing template Assets.Misc." .. config.ModelName)
		return false, "missing-template"
	end

	local spawnPart, code = pickFreeSpawn()
	if not spawnPart then
		return false, code
	end
	local floorTopY = Pinata.FloorTopY()
	if not floorTopY then
		warn("[PinataService] Missing " .. Pinata.SpawnFolderName .. "." .. Pinata.FloorPartName)
		return false, "no-pinata-floor"
	end

	local model = template:Clone()
	prepareSpawnedModel(model)
	if not model.PrimaryPart then
		local fallback = model:FindFirstChildWhichIsA("BasePart", true)
		if not fallback then
			model:Destroy()
			return false, "template-has-no-parts"
		end
		model.PrimaryPart = fallback
	end

	nextPinataId += 1
	local id = nextPinataId
	local now = serverNow()

	-- Spawned at its RESTING pivot; the 20-stud fall is a client-side
	-- presentation derived from DropAt, so the server's distance checks and the
	-- authoritative position agree from the first frame.
	--
	-- The marker supplies X/Z only. Height comes from the PinataFloor slab so
	-- every pinata rests on the same plane regardless of the marker's own Y or
	-- how tall the variant is (Golden is nearly twice Default).
	model:PivotTo(Pinata.RestingPivot(model, spawnPart, floorTopY) or CFrame.new(spawnPart.Position))
	model.Name = string.format("Pinata_%d", id)
	model:SetAttribute(State.Pinata.Id, id)
	model:SetAttribute(State.Pinata.Variant, variantId)
	model:SetAttribute(State.Pinata.Hp, config.MaxHp)
	model:SetAttribute(State.Pinata.MaxHp, config.MaxHp)
	model:SetAttribute(State.Pinata.DropAt, now)
	model:SetAttribute(State.Pinata.ExpiresAt, now + Pinata.LifetimeSeconds)
	model.Parent = runtime()

	pinatas[id] = {
		id = id,
		variantId = variantId,
		config = config,
		model = model,
		primary = model.PrimaryPart,
		spawnPart = spawnPart,
		hp = config.MaxHp,
		publishedHp = config.MaxHp,
		lastPublish = os.clock(),
		dropAt = now,
		expiresAt = now + Pinata.LifetimeSeconds,
		ledger = {},
		broken = false,
	}

	announceSpawn(config)
	TelemetryService.Record("pinata_spawned", {
		pinataId = id,
		variant = variantId,
		maxHp = config.MaxHp,
	})
	return true, id
end

-- ── Rewards ───────────────────────────────────────────────────────────────────

local function grantGrowSkip(player, context, rewardId)
	local seconds = Pinata.GrowSkipSeconds(rewardId)
	if seconds <= 0 then
		return false, "invalid-skip"
	end
	local result, code = GrowSkipService.ApplyFreePlotTimeSkip(player, context.plot, seconds)
	if not result then
		-- Unlike the Endless Pack claim track, this drop is a physical object
		-- the player walked into. Silently consuming it for no effect reads as
		-- broken, so leave it on the ground and say why.
		return false, code or "no-growth"
	end
	NotificationService.Success(player, string.format("Pinata: skipped %dm of growing time!", seconds // 60))
	return true, "ok"
end

local function grantCash(player, context, rewardId, payout)
	payout = tonumber(payout) or 0
	if payout <= 0 then
		return false, "income-unavailable"
	end
	local _, addCode = CurrencyService.Add(player, context.profile, payout, true)
	if addCode == "busy" then
		return false, "currency-busy"
	end
	CurrencyService.Publish(player, context.profile)
	NotificationService.Success(player, "Pinata: +" .. NumberFormatter.Currency(payout) .. "!")
	return true, "ok"
end

local function grantDurianTicket(player, context, amount)
	amount = math.max(math.floor(tonumber(amount) or 0), 0)
	if amount <= 0 then
		return false, "invalid-amount"
	end
	local profile = context.profile
	local previous = math.max(math.floor(tonumber(profile.Data.DurianTickets) or 0), 0)
	local granted = false
	local ok, err = pcall(function()
		profile.Data.DurianTickets = previous + amount
		local saved = true
		local saveOk = pcall(function()
			profile:Save()
		end)
		if not saveOk then
			saved = false
		end
		if not saved then
			profile.Data.DurianTickets = previous
			return
		end
		granted = true
	end)
	if not ok then
		warn("[PinataService] Durian ticket grant failed: " .. tostring(err))
		profile.Data.DurianTickets = previous
		granted = false
	end
	PlayerReplicaService.PublishDurianPack(player, profile)
	if not granted then
		return false, "save-failed"
	end
	NotificationService.Success(player, string.format(
		"Pinata: %d Durian Ticket%s!",
		amount,
		amount == 1 and "" or "s"
	))
	return true, "ok"
end

-- Applies one collected drop. Returns (true) when the drop should be consumed,
-- or (false, code) to leave it on the ground.
local function applyReward(player, rewardId, payout)
	local reward = Pinata.RewardConfig(rewardId)
	if not reward then
		return false, "unknown-reward"
	end
	local context, code = EventEligibility.Context(player)
	if not context then
		return false, code
	end
	if blocked(player) then
		return false, "gameplay-blocked"
	end

	local ok, resultCode
	if reward.Kind == Pinata.RewardKinds.GrowSkip then
		ok, resultCode = grantGrowSkip(player, context, rewardId)
	elseif reward.Kind == Pinata.RewardKinds.Cash then
		ok, resultCode = grantCash(player, context, rewardId, payout)
	elseif reward.Kind == Pinata.RewardKinds.DurianTicket then
		ok, resultCode = grantDurianTicket(player, context, reward.Amount)
	else
		return false, "unhandled-kind"
	end

	if ok then
		TelemetryService.Record("pinata_reward_granted", TelemetryService.ForPlayer(player, {
			rewardId = rewardId,
			kind = reward.Kind,
			payout = payout,
		}))
	end
	return ok, resultCode
end

-- ── Drops ─────────────────────────────────────────────────────────────────────

-- Scatter position on the pinata floor. Uses the PinataFloor plane rather than a
-- downward raycast: the raycast could land on the pinata's own geometry, a
-- player, or another drop, which is what made drop heights inconsistent.
--
-- Drops are spread over three rings around a base angle that steps evenly with
-- the index, then jittered. Without the jitter the ring index stays locked to
-- the angle and the burst lands as a visible three-armed spiral rather than a
-- scatter. Only the server computes this and the result replicates, so plain
-- randomness is fine -- no cross-client agreement is needed.
local function groundPositionNear(origin, index, total, floorTopY, rng)
	local count = math.max(total, 1)
	local step = (math.pi * 2) / count
	local angle = index * step + rng:NextNumber(-step * 0.5, step * 0.5)
	local ring = (0.35 + 0.65 * (index % 3) / 2)
	local radius = Pinata.DropScatterRadius * ring * rng:NextNumber(0.85, 1.15)
	local x = origin.X + math.cos(angle) * radius
	local z = origin.Z + math.sin(angle) * radius
	-- Rest the 2x2x2 reward part on the floor.
	return Vector3.new(x, floorTopY + 1, z)
end

local function spawnDrop(ownerId, rewardId, payout, origin, index, total, floorTopY, rng)
	local misc = miscFolder()
	local rewardsFolder = misc and misc:FindFirstChild(Pinata.RewardsFolderName)
	local template = rewardsFolder and rewardsFolder:FindFirstChild(rewardId)
	if not (template and template:IsA("BasePart")) then
		warn("[PinataService] Missing reward template " .. tostring(rewardId))
		return nil
	end

	local part = template:Clone()
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Position = groundPositionNear(origin, index, total, floorTopY, rng)
	for _, descendant in ipairs(part:GetDescendants()) do
		if descendant:IsA("BillboardGui") then
			-- Hidden by default; each client enables only its own drops.
			descendant.Enabled = false
		end
	end

	local now = serverNow()
	part:SetAttribute(State.Pinata.DropOwner, ownerId)
	part:SetAttribute(State.Pinata.DropReward, rewardId)
	part:SetAttribute(State.Pinata.DropOrigin, origin)
	part:SetAttribute(State.Pinata.DropSpawnedAt, now)
	part.Parent = dropsRoot()

	drops[part] = {
		part = part,
		ownerId = ownerId,
		rewardId = rewardId,
		payout = payout,
		-- Inert until the client's arc animation has landed.
		armedAt = os.clock() + Pinata.DropArmDelaySeconds,
		expiresAt = os.clock() + Pinata.DropArmDelaySeconds + Pinata.DropCollectSeconds,
	}
	return part
end

local function collectDrop(record, player)
	local ok, code = applyReward(player, record.rewardId, record.payout)
	if not ok then
		return false, code
	end
	drops[record.part] = nil
	record.part:Destroy()
	return true, "ok"
end

-- ── Break and split ───────────────────────────────────────────────────────────

local function presentLedger(record)
	-- Physical drops require presence, so a leaver's damage is dropped and the
	-- remaining contributors are renormalised over what is left.
	local present = {}
	for userId, damage in pairs(record.ledger) do
		local player = Players:GetPlayerByUserId(userId)
		if player and player.Parent == Players then
			present[userId] = damage
		end
	end
	return present
end

local function breakPinata(record, reason)
	if record.broken then
		return
	end
	record.broken = true

	local origin = record.primary and record.primary.Position
		or (record.spawnPart and record.spawnPart.Position)
		or Vector3.zero
	-- Fall back to the pinata's own base if the floor slab has gone missing, so
	-- a break still pays out rather than dropping rewards into the void.
	local floorTopY = Pinata.FloorTopY() or origin.Y
	local scatterRng = Random.new()
	local ledger = presentLedger(record)
	local allocation, shares = Pinata.SplitRewards(ledger, record.config.Pool, record.config.MaxHp)

	-- Cash is snapshotted at allocation time so the pickup is deterministic and
	-- cannot be gamed by delaying collection until income is higher.
	local totalDrops = 0
	for _, perReward in pairs(allocation) do
		for _, count in pairs(perReward) do
			totalDrops += count
		end
	end

	local index = 0
	for userId, perReward in pairs(allocation) do
		local player = Players:GetPlayerByUserId(userId)
		local hourly = 0
		if player then
			local okIncome, income = pcall(PetIncomeService.Refresh, player)
			hourly = okIncome and tonumber(income) or 0
		end
		for rewardId, count in pairs(perReward) do
			local reward = Pinata.RewardConfig(rewardId)
			local payout = 0
			if reward and reward.Kind == Pinata.RewardKinds.Cash then
				payout = ShopBalance.PinataCashPayout(reward.CashId, hourly)
			end
			for _ = 1, count do
				index += 1
				RuntimeGuard.Run("PinataService.SpawnDrop", spawnDrop, userId, rewardId, payout, origin, index, totalDrops, floorTopY, scatterRng)
			end
		end
	end

	TelemetryService.Record("pinata_broken", {
		pinataId = record.id,
		variant = record.variantId,
		reason = reason,
		contributors = (function()
			local n = 0
			for _ in pairs(shares) do
				n += 1
			end
			return n
		end)(),
		drops = totalDrops,
	})

	if record.model and record.model.Parent then
		record.model:SetAttribute(State.Pinata.Hp, 0)
		setParticles(record.model, true)
		local model = record.model
		task.delay(BREAK_LINGER_SECONDS, function()
			if model and model.Parent then
				model:Destroy()
			end
		end)
	end
	pinatas[record.id] = nil
end

local function removePinata(record)
	pinatas[record.id] = nil
	if record.model and record.model.Parent then
		record.model:Destroy()
	end
end

-- ── Swings ────────────────────────────────────────────────────────────────────

local function nearestPinata(player, maxDistance)
	local root = rootPart(player)
	if not root then
		return nil
	end
	local best, bestDistance = nil, math.huge
	for _, record in pairs(pinatas) do
		if not record.broken and record.model and record.model.Parent then
			-- Surface distance, not pivot distance: pinatas hang well above the
			-- ground, so pivot distance would put a player standing underneath
			-- one out of reach. See Pinata.DistanceToModel.
			local distance = Pinata.DistanceToModel(record.model, root.Position)
			if distance <= maxDistance and distance < bestDistance then
				best, bestDistance = record, distance
			end
		end
	end
	return best
end

local function publishHp(record, force)
	local now = os.clock()
	if not force and now - record.lastPublish < HP_PUBLISH_INTERVAL then
		return
	end
	record.lastPublish = now
	if record.publishedHp ~= record.hp and record.model and record.model.Parent then
		record.publishedHp = record.hp
		record.model:SetAttribute(State.Pinata.Hp, record.hp)
	end
end

local function onSwing(player)
	local key = userKey(player)
	if not key then
		return
	end

	-- Cooldown FIRST, deliberately. It is the only thing bounding damage rate,
	-- for exploiters and honest players alike, and checking it before the
	-- (more expensive, telemetry-emitting) eligibility gate means a client
	-- spamming the remote is dropped cheaply and cannot flood telemetry.
	-- There is no per-player damage cap on top of this: it would add no
	-- security and would make solo breaking impossible.
	local now = os.clock()
	local previous = swingCooldown[key]
	if previous and now - previous < Pinata.SwingCooldownSeconds then
		return
	end
	swingCooldown[key] = now

	local eligible, code = EventEligibility.IsEligible(player)
	if not eligible then
		TelemetryService.Warn("pinata_swing_rejected", TelemetryService.ForPlayer(player, { reason = code }))
		return
	end
	if blocked(player) then
		return
	end

	local record = nearestPinata(player, Pinata.SwingReachStuds)
	if not record then
		return
	end
	if not Pinata.HasLanded(serverNow() - record.dropAt) then
		return
	end

	record.hp = math.max(record.hp - Pinata.SwingDamage, 0)
	record.ledger[key] = (record.ledger[key] or 0) + Pinata.SwingDamage

	if record.hp <= 0 then
		publishHp(record, true)
		breakPinata(record, "broken")
		return
	end
	publishHp(record, false)
end

-- ── Stick ─────────────────────────────────────────────────────────────────────

local function destroyStick(userId)
	local stick = sticks[userId]
	sticks[userId] = nil
	if stick and stick.Parent then
		stick:Destroy()
	end
end

local function weldStick(player)
	local character = player.Character
	local hand = character and (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm"))
	if not (hand and hand:IsA("BasePart")) then
		return nil
	end
	local misc = miscFolder()
	local template = misc and misc:FindFirstChild(Pinata.StickModelName)
	if not (template and template:IsA("Model")) then
		return nil
	end

	local model = template:Clone()
	model.Name = Pinata.StickAccessoryName
	local handle = model.PrimaryPart or model:FindFirstChild(Pinata.StickHandleName)
	if not (handle and handle:IsA("BasePart")) then
		model:Destroy()
		return nil
	end

	local parts = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			-- Massless so a cosmetic prop cannot perturb character physics.
			descendant.Massless = true
			parts[#parts + 1] = descendant
		end
	end
	if #parts == 0 then
		model:Destroy()
		return nil
	end

	-- Parent BEFORE welding: welds between parts outside the DataModel do not
	-- initialise reliably.
	model.Parent = character

	-- Move the WHOLE model rigidly so the handle lands in the palm. Moving only
	-- the handle (and leaving the mesh at its template position) is what makes
	-- a WeldConstraint lock in a huge offset and send the stick flying.
	local target = hand.CFrame * STICK_GRIP_OFFSET
	local delta = target * handle.CFrame:Inverse()
	for _, part in ipairs(parts) do
		part.CFrame = delta * part.CFrame
	end

	-- Now that every part sits at its intended relative pose, freeze the model
	-- to the handle, then pin the handle to the hand at the exact measured
	-- offset (rather than re-deriving it and risking a mismatch).
	for _, part in ipairs(parts) do
		if part ~= handle then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "PinataStickPartWeld"
			weld.Part0 = handle
			weld.Part1 = part
			weld.Parent = part
		end
	end

	local weld = Instance.new("Weld")
	weld.Name = "PinataStickWeld"
	weld.Part0 = hand
	weld.Part1 = handle
	weld.C0 = hand.CFrame:ToObjectSpace(handle.CFrame)
	weld.C1 = CFrame.identity
	weld.Parent = handle

	return model
end

local function refreshSticks()
	for _, player in ipairs(Players:GetPlayers()) do
		local key = userKey(player)
		if key then
			local wanted = false
			if not blocked(player) and rootPart(player) then
				wanted = nearestPinata(player, Pinata.AutoEquipRadius) ~= nil
			end

			local existing = sticks[key]
			if existing and (not existing.Parent or existing.Parent ~= player.Character) then
				destroyStick(key)
				existing = nil
			end
			if wanted and not existing then
				-- RuntimeGuard.Run returns (ok, results...).
				local ok, stick = RuntimeGuard.Run("PinataService.WeldStick", weldStick, player)
				if ok and typeof(stick) == "Instance" then
					sticks[key] = stick
				end
			elseif not wanted and existing then
				destroyStick(key)
			end
		end
	end
end

-- ── Sweeps ────────────────────────────────────────────────────────────────────

local function sweepDrops()
	local now = os.clock()
	for part, record in pairs(drops) do
		if not part.Parent then
			drops[part] = nil
		elseif now >= record.expiresAt then
			-- Uncollected: credit the owner rather than letting a reward they
			-- legitimately earned evaporate because they wandered off.
			local owner = Players:GetPlayerByUserId(record.ownerId)
			if owner then
				RuntimeGuard.Run("PinataService.AutoGrantDrop", collectDrop, record, owner)
			end
			if drops[part] then
				drops[part] = nil
				part:Destroy()
			end
		elseif now >= record.armedAt then
			local owner = Players:GetPlayerByUserId(record.ownerId)
			local root = owner and rootPart(owner)
			if root and (root.Position - part.Position).Magnitude <= Pinata.DropCollectRadius then
				RuntimeGuard.Run("PinataService.CollectDrop", collectDrop, record, owner)
			end
		end
	end
end

local function sweepPinatas()
	local now = serverNow()
	for _, record in pairs(pinatas) do
		if record.broken then
			continue
		end
		if not (record.model and record.model.Parent) then
			pinatas[record.id] = nil
			continue
		end
		publishHp(record, false)
		if now >= record.expiresAt then
			local hasDamage = next(record.ledger) ~= nil
			if hasDamage then
				-- Contributors keep what they earned; a 249/250 wipe would be a
				-- pure feel-bad and an obvious timing grief.
				breakPinata(record, "expired")
			else
				removePinata(record)
			end
		end
	end
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

-- Removes every pinata and every uncollected drop, with no payout. This is the
-- admin kill switch, so it is deliberately not a break.
function PinataService.ClearAll()
	local cleared = 0
	for id, record in pairs(pinatas) do
		pinatas[id] = nil
		cleared += 1
		if record.model and record.model.Parent then
			record.model:Destroy()
		end
	end
	for part in pairs(drops) do
		drops[part] = nil
		if part.Parent then
			part:Destroy()
		end
	end
	for userId in pairs(sticks) do
		destroyStick(userId)
	end
	return cleared
end

function PinataService.ActiveCount()
	local count = 0
	for _ in pairs(pinatas) do
		count += 1
	end
	return count
end

-- Diagnostics for Studio/MCP verification.
function PinataService.Debug()
	local list = {}
	for id, record in pairs(pinatas) do
		local contributors = {}
		for userId, damage in pairs(record.ledger) do
			contributors[tostring(userId)] = damage
		end
		list[#list + 1] = {
			id = id,
			variant = record.variantId,
			hp = record.hp,
			maxHp = record.config.MaxHp,
			secondsLeft = math.floor(record.expiresAt - serverNow()),
			ledger = contributors,
		}
	end
	local dropCount = 0
	for _ in pairs(drops) do
		dropCount += 1
	end
	return { pinatas = list, drops = dropCount, sticks = (function()
		local n = 0
		for _ in pairs(sticks) do
			n += 1
		end
		return n
	end)() }
end

-- Studio-only test hook: applies damage without the swing cooldown so the
-- break/split/drop/collect path can be exercised without 250 real swings.
-- Never available live -- the same RunService:IsStudio() gate AdminPanelService
-- uses for its local-test-client allowance.
function PinataService.DebugDamage(pinataId, userId, amount)
	if not RunService:IsStudio() then
		return false, "studio-only"
	end
	local record = pinatas[tonumber(pinataId) or -1]
	if not record or record.broken then
		return false, "unknown-pinata"
	end
	local key = tonumber(userId)
	amount = math.max(math.floor(tonumber(amount) or 0), 0)
	if not key or amount <= 0 then
		return false, "invalid-args"
	end
	record.hp = math.max(record.hp - amount, 0)
	record.ledger[key] = (record.ledger[key] or 0) + amount
	if record.hp <= 0 then
		publishHp(record, true)
		breakPinata(record, "debug")
		return true, "broken"
	end
	publishHp(record, true)
	return true, record.hp
end

local function onPlayerRemoving(player)
	local key = userKey(player)
	if not key then
		return
	end
	destroyStick(key)
	swingCooldown[key] = nil
	-- Ledger entries are left in place; presentLedger filters absent players at
	-- break time, which keeps a rejoin within the same pinata's life harmless.
end

function PinataService.Shutdown()
	if sweepConnection then
		sweepConnection:Disconnect()
		sweepConnection = nil
	end
	if stickConnection then
		stickConnection:Disconnect()
		stickConnection = nil
	end
	PinataService.ClearAll()
	if runtimeFolder and runtimeFolder.Parent then
		runtimeFolder:Destroy()
		runtimeFolder = nil
	end
	if dropsFolder and dropsFolder.Parent then
		dropsFolder:Destroy()
		dropsFolder = nil
	end
	started = false
end

function PinataService.Start(config)
	if started then
		return
	end
	started = true
	config = type(config) == "table" and config or {}
	isGameplayBlocked = config.isGameplayBlocked

	runtime()
	dropsRoot()

	RuntimeGuard.Connect(swingRemote.OnServerEvent, "PinataService.SwingRequest", function(player)
		onSwing(player)
	end)
	RuntimeGuard.Connect(Players.PlayerRemoving, "PinataService.PlayerRemoving", onPlayerRemoving)

	local dropAccumulator = 0
	local stickAccumulator = 0
	sweepConnection = RuntimeGuard.Connect(RunService.Heartbeat, "PinataService.Sweep", function(dt)
		dropAccumulator += dt
		stickAccumulator += dt
		if dropAccumulator >= SWEEP_INTERVAL then
			dropAccumulator = 0
			RuntimeGuard.Run("PinataService.SweepPinatas", sweepPinatas)
			RuntimeGuard.Run("PinataService.SweepDrops", sweepDrops)
		end
		if stickAccumulator >= STICK_SWEEP_INTERVAL then
			stickAccumulator = 0
			RuntimeGuard.Run("PinataService.RefreshSticks", refreshSticks)
		end
	end)
end

return PinataService
