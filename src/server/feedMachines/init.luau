-- Registry + dispatcher for FeedMachine templates.
--
-- Templates live at ReplicatedStorage.Assets.FeedMachines.<Class>.<DisplayName>.
-- A template can be a BasePart or a Model. The template carries:
--   FeedClass  (string, broad behavior class, e.g. "Patch", "Processor", "JamBarrel", or "Tree")
--   FeedType   (string, stable gameplay id; template/model Name is visual only)
--   Rarity     (string, display rarity; see Shared.Rarities)
--   FoodType   (string, accepted food category, Processor only; JamBarrel accepts any food)
--   FoodDrop   (string, exact produced food id, see Shared.Food)
--   plus class- or type-specific tunables (see Shared.State.Feed)
--
-- Dispatch starts from FeedType. The registry maps that stable id to the
-- template's FeedClass; the containing folder is only the default when
-- FeedClass is omitted.
--
-- Each module conforms to:
--   class.Setup(machine, plot, owner)         -- wire interactions; init state
--   class.Teardown(machine)         optional  -- destroy state, default: noop
--   class.Serialize(machine) -> tbl optional  -- extra fields to merge into placement
--   class.Apply(machine, placement) optional  -- restore state from placement
--
-- The registry hooks machine.Destroying to call Teardown automatically.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.Shared:WaitForChild("Assets"))
local RuntimeGuard = require(ReplicatedStorage.Shared:WaitForChild("RuntimeGuard"))
local State = require(ReplicatedStorage.Shared:WaitForChild("State"))

local Trees = require(script:WaitForChild("Trees"))
local Patches   = require(script:WaitForChild("Patches"))
local JamBarrel = require(script:WaitForChild("JamBarrel"))
local Processor = require(script:WaitForChild("Processor"))

-- Class-level implementations.
local CLASSES = {
	JamBarrel = JamBarrel,
	Patch     = Patches,
	Processor = Processor,
	Tree      = Trees,
}

local FeedMachines = {}

-- ── Template index ────────────────────────────────────────────────────────────

local index  -- { [feedType] = { template = Instance, class = string } }

local function buildIndex()
	local result = {}
	local root = Assets.WaitFor(Assets.Names.FeedMachines)
	for _, classFolder in ipairs(root:GetChildren()) do
		if classFolder:IsA("Folder") then
			for _, template in ipairs(classFolder:GetChildren()) do
				-- Templates can be BasePart or Model.
				local isPart  = template:IsA("BasePart")
				local isModel = template:IsA("Model")
				if isPart or isModel then
					local feedType = template:GetAttribute(State.Feed.Type)
					if type(feedType) ~= "string" or feedType == "" then
						warn(string.format(
							"[FeedMachines] Skipping %s: missing %s attribute",
							template:GetFullName(),
							State.Feed.Type
						))
						continue
					end
					if result[feedType] then
						warn(string.format(
							"[FeedMachines] Duplicate FeedType %q (in %s)",
							feedType, classFolder.Name
						))
						continue
					end
					local feedClass = template:GetAttribute(State.Feed.Class)
					if type(feedClass) ~= "string" or feedClass == "" then
						feedClass = classFolder.Name
						template:SetAttribute(State.Feed.Class, feedClass)
					end
					if not CLASSES[feedClass] then
						warn(string.format(
							"[FeedMachines] Skipping %s: unknown %s %q",
							template:GetFullName(),
							State.Feed.Class,
							tostring(feedClass)
						))
						continue
					end
					result[feedType] = {
						template = template,
						class    = feedClass,
					}
				end
			end
		end
	end
	return result
end

local function getIndex()
	index = index or buildIndex()
	return index
end

function FeedMachines.GetTemplate(feedType)
	local rec = getIndex()[feedType]
	return rec and rec.template or nil
end

function FeedMachines.GetClass(feedType)
	local rec = getIndex()[feedType]
	return rec and rec.class or nil
end

function FeedMachines.IsClass(feedClass)
	return CLASSES[feedClass] ~= nil
end

function FeedMachines.AllFeedTypes()
	local out = {}
	for ft in pairs(getIndex()) do out[#out+1] = ft end
	table.sort(out)
	return out
end

-- ── Dynamic XP (PercentageOfBest) ─────────────────────────────────────────────

-- Mirrors FeedGrowthService's phase marker; growing-seed visuals never had
-- Setup and must not count toward (or receive) dynamic XP. Read via attribute
-- because requiring FeedGrowthService here would be circular.
local GROWING_SEED_PHASE = "GrowingSeed"

local function percentageOfBestOf(machine)
	local pct = machine:GetAttribute(State.Feed.PercentageOfBest)
	if type(pct) == "number" and pct > 0 then
		return pct
	end
	return nil
end

-- Recomputes every PercentageOfBest machine's effective XP attribute from the
-- best same-class static machine on the plot. Placed machines are direct plot
-- children (PlotService parents clones to the plot); templates are untouched.
function FeedMachines.RecomputeDynamicXP(plot)
	if not plot or not plot.Parent then return end
	local best = {} -- [feedClass] = highest static XP
	local dynamic = {} -- { { machine, class, pct } }
	for _, child in ipairs(plot:GetChildren()) do
		local feedType = child:GetAttribute(State.Feed.Type)
		if type(feedType) ~= "string" or child:GetAttribute(State.Feed.Index) == nil then
			continue
		end
		if child:GetAttribute(State.Seed.Phase) == GROWING_SEED_PHASE then
			continue
		end
		local feedClass = FeedMachines.GetClass(feedType)
		if feedClass ~= "Tree" and feedClass ~= "Patch" then
			continue
		end
		local pct = percentageOfBestOf(child)
		if pct then
			table.insert(dynamic, { machine = child, class = feedClass, pct = pct })
		else
			local xp = child:GetAttribute(State.Feed.XP)
			-- Same defaults as Trees.xpMultiplierFor / PatchScale.NormalizePatchXP.
			xp = (type(xp) == "number" and xp > 0) and xp or 1
			if xp > (best[feedClass] or 0) then
				best[feedClass] = xp
			end
		end
	end
	for _, entry in ipairs(dynamic) do
		local base = best[entry.class]
		local resolved = base and math.max(entry.pct * base, 1) or 1
		if entry.class == "Patch" then
			Patches.SetResolvedPatchXP(entry.machine, resolved)
		else
			-- Trees read the attribute live on every drop.
			entry.machine:SetAttribute(State.Feed.XP, resolved)
		end
	end
end

-- Coalesces the many Setup/Destroying calls of a plot load or teardown into a
-- single recompute per plot per frame.
local dirtyPlots = {}
local function markPlotDirty(plot)
	if not plot or dirtyPlots[plot] then return end
	dirtyPlots[plot] = true
	task.defer(function()
		dirtyPlots[plot] = nil
		RuntimeGuard.Run("FeedMachines.RecomputeDynamicXP", FeedMachines.RecomputeDynamicXP, plot)
	end)
end

-- ── Dispatch ──────────────────────────────────────────────────────────────────

local function feedTypeOf(machine)
	local feedType = machine:GetAttribute(State.Feed.Type)
	if type(feedType) == "string" and feedType ~= "" then
		return feedType
	end
	return nil
end

local function classOf(machine)
	local feedType = feedTypeOf(machine)
	if not feedType then return nil end
	return FeedMachines.GetClass(feedType)
end

local function impl(machine)
	local cls = classOf(machine)
	return CLASSES[cls], cls
end

function FeedMachines.Setup(machine, plot, owner)
	local mod, name = impl(machine)
	if not mod then
		warn(string.format("[FeedMachines] No implementation for %s", tostring(name)))
		return false, "no-implementation"
	end
	machine:SetAttribute(State.Feed.Class, name)
	local ok = RuntimeGuard.Run("FeedMachines.Setup." .. tostring(name), mod.Setup, machine, plot, owner)
	if not ok then
		return false, "setup-failed"
	end
	-- Auto-cleanup when the part dies during plot resets or lifecycle teardown.
	RuntimeGuard.Connect(machine.Destroying, "FeedMachines.Destroying." .. tostring(name), function()
		FeedMachines.Teardown(machine)
		-- Membership changed; the destroyed machine self-excludes at defer
		-- time (Parent == nil).
		markPlotDirty(plot)
	end)
	markPlotDirty(plot)
	return true
end

function FeedMachines.Teardown(machine)
	local mod = impl(machine)
	if mod and mod.Teardown then
		RuntimeGuard.Run("FeedMachines.Teardown", mod.Teardown, machine)
	end
end

function FeedMachines.Serialize(machine)
	local mod = impl(machine)
	if mod and mod.Serialize then
		local ok, result = RuntimeGuard.Run("FeedMachines.Serialize", mod.Serialize, machine)
		return ok and result or nil
	end
	return nil
end

function FeedMachines.Apply(machine, placement, options)
	if not placement then return end
	local mod = impl(machine)
	if mod and mod.Apply then
		RuntimeGuard.Run("FeedMachines.Apply", mod.Apply, machine, placement, options)
	end
end

function FeedMachines.ApplyOfflineProgress(machine, context)
	local mod = impl(machine)
	if mod and mod.ApplyOfflineProgress then
		local ok, result = RuntimeGuard.Run("FeedMachines.ApplyOfflineProgress", mod.ApplyOfflineProgress, machine, context)
		return ok == true and result ~= false
	end
	return true
end

function FeedMachines.HasGrowthCreditTarget(machine)
	local mod = impl(machine)
	if mod and mod.HasGrowthCreditTarget then
		local ok, result = RuntimeGuard.Run("FeedMachines.HasGrowthCreditTarget", mod.HasGrowthCreditTarget, machine)
		return ok == true and result == true
	end
	return false
end

function FeedMachines.CreditGrowthSeconds(machine, seconds)
	local mod = impl(machine)
	if mod and mod.CreditGrowthSeconds then
		local results = table.pack(RuntimeGuard.Run("FeedMachines.CreditGrowthSeconds", mod.CreditGrowthSeconds, machine, seconds))
		if results[1] ~= true then
			return false, "credit-failed"
		end
		return table.unpack(results, 2, results.n)
	end
	return false, "unsupported"
end

-- Re-syncs server-side visual geometry (e.g. patch slot fruit scale) so a
-- subsequent pivot replicates a consistent snapshot. Optional per class.
function FeedMachines.ResyncVisualScales(machine)
	local mod = impl(machine)
	if mod and mod.ResyncVisualScales then
		RuntimeGuard.Run("FeedMachines.ResyncVisualScales", mod.ResyncVisualScales, machine)
	end
end

function FeedMachines.CollectMutationTargets(machine, mutationId)
	local mod = impl(machine)
	if mod and mod.CollectMutationTargets then
		local ok, targets = RuntimeGuard.Run("FeedMachines.CollectMutationTargets", mod.CollectMutationTargets, machine, mutationId)
		if ok and type(targets) == "table" then
			return targets
		end
	end
	return {}
end

function FeedMachines.ApplyMutation(machine, targetKey, mutationId)
	local mod = impl(machine)
	if mod and mod.ApplyMutation then
		local results = table.pack(RuntimeGuard.Run("FeedMachines.ApplyMutation", mod.ApplyMutation, machine, targetKey, mutationId))
		if results[1] ~= true then
			return false, "apply-failed"
		end
		return table.unpack(results, 2, results.n)
	end
	return false, "unsupported"
end

function FeedMachines.ReserveCollectAll(machine, player, reservationId, expiresAt, limit)
	local mod = impl(machine)
	if mod and mod.ReserveCollectAll then
		local results = table.pack(RuntimeGuard.Run(
			"FeedMachines.ReserveCollectAll",
			mod.ReserveCollectAll,
			machine,
			player,
			reservationId,
			expiresAt,
			limit
		))
		if results[1] ~= true then
			return false, "reserve-failed"
		end
		return table.unpack(results, 2, results.n)
	end
	return false, "unsupported"
end

function FeedMachines.ReleaseCollectAll(machine, item, reservationId)
	local mod = impl(machine)
	if mod and mod.ReleaseCollectAll then
		local ok, released = RuntimeGuard.Run("FeedMachines.ReleaseCollectAll", mod.ReleaseCollectAll, machine, item, reservationId)
		return ok == true and released == true
	end
	return false
end

function FeedMachines.CommitCollectAll(machine, item, reservationId)
	local mod = impl(machine)
	if mod and mod.CommitCollectAll then
		local results = table.pack(RuntimeGuard.Run("FeedMachines.CommitCollectAll", mod.CommitCollectAll, machine, item, reservationId))
		if results[1] ~= true then
			return nil
		end
		return table.unpack(results, 2, results.n)
	end
	return nil
end

function FeedMachines.BlocksPetNavigation(machine, now)
	local mod = impl(machine)
	if mod and mod.BlocksPetNavigation then
		local ok, blocks, token = RuntimeGuard.Run("FeedMachines.BlocksPetNavigation", mod.BlocksPetNavigation, machine, now)
		if ok and type(blocks) == "boolean" then
			if type(token) ~= "string" or token == "" then
				token = blocks and "block" or "walkable"
			end
			return blocks, token
		end
	end
	return true, "block"
end

function FeedMachines.Interact(machine, player)
	local mod = impl(machine)
	if mod and mod.Interact then
		local ok, result = RuntimeGuard.Run("FeedMachines.Interact", mod.Interact, machine, player)
		return ok and result or nil
	end
	return nil
end

function FeedMachines.HarvestPatchAnchor(anchor, player)
	local results = table.pack(RuntimeGuard.Run("FeedMachines.HarvestPatchAnchor", Patches.HarvestAnchor, anchor, player))
	if results[1] ~= true then
		return nil
	end
	return table.unpack(results, 2, results.n)
end

function FeedMachines.PickupTreeGround(ground, player)
	local results = table.pack(RuntimeGuard.Run("FeedMachines.PickupTreeGround", Trees.PickupGround, ground, player))
	if results[1] ~= true then
		return nil
	end
	return table.unpack(results, 2, results.n)
end

function FeedMachines.ReserveStealTarget(target, player, reservationId, expiresAt)
	local patchResults = table.pack(RuntimeGuard.Run("FeedMachines.ReserveStealPatch", Patches.ReserveStealTarget, target, player, reservationId, expiresAt))
	if patchResults[1] == true and patchResults[2] == true then
		return table.unpack(patchResults, 2, patchResults.n)
	end
	local treeResults = table.pack(RuntimeGuard.Run("FeedMachines.ReserveStealTree", Trees.ReserveStealTarget, target, player, reservationId, expiresAt))
	if treeResults[1] == true and treeResults[2] == true then
		return table.unpack(treeResults, 2, treeResults.n)
	end
	if patchResults[1] == true and patchResults[3] and patchResults[3] ~= "not-patch" then
		return false, patchResults[3]
	end
	if treeResults[1] == true then
		return false, treeResults[3]
	end
	return false, "invalid-target"
end

function FeedMachines.ReleaseSteal(machine, reservation, reservationId)
	local mod = impl(machine)
	if mod and mod.ReleaseSteal then
		local ok, released = RuntimeGuard.Run("FeedMachines.ReleaseSteal", mod.ReleaseSteal, machine, reservation, reservationId)
		return ok == true and released == true
	end
	return false
end

function FeedMachines.CommitSteal(machine, reservation, reservationId)
	local mod = impl(machine)
	if mod and mod.CommitSteal then
		local results = table.pack(RuntimeGuard.Run("FeedMachines.CommitSteal", mod.CommitSteal, machine, reservation, reservationId))
		if results[1] ~= true then
			return nil
		end
		return table.unpack(results, 2, results.n)
	end
	return nil
end

function FeedMachines.StressClickTree(machine, player)
	local results = table.pack(RuntimeGuard.Run("FeedMachines.StressClickTree", Trees.StressClick, machine, player))
	if results[1] ~= true then
		return nil
	end
	return table.unpack(results, 2, results.n)
end

return FeedMachines
