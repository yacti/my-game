-- Registry + dispatcher for FeedMachine templates.
--
-- Templates live at ReplicatedStorage.FeedMachines.<Class>.<TemplateName>.
-- A template can be a BasePart (e.g. Clicker1) or a Model (e.g.
-- PumpkinPatch). The template carries:
--   FeedClass  (string, broad behavior class, e.g. "Clicker", "Patch", or "Tree")
--   FeedType   (string, equals template name; what the rest of the codebase keys on)
--   FoodType   (string, foodType produced/accepted, see Shared.Food)
--   plus class- or type-specific tunables (see Shared.State.Feed)
--
-- Dispatch is by FeedClass. Add a small per-type override table only when a
-- feed type needs behavior that differs from its class.
--
-- Each module conforms to:
--   class.Setup(machine, plot, owner)         -- wire interactions; init state
--   class.Teardown(machine)         optional  -- destroy state, default: noop
--   class.Serialize(machine) -> tbl optional  -- extra fields to merge into placement
--   class.Apply(machine, placement) optional  -- restore state from placement
--
-- The registry hooks machine.Destroying to call Teardown automatically.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local State = require(ReplicatedStorage.Shared:WaitForChild("State"))

local Trees = require(script:WaitForChild("Trees"))
local Clicker   = require(script:WaitForChild("Clicker"))
local Patches   = require(script:WaitForChild("Patches"))
local Processor = require(script:WaitForChild("Processor"))

-- Class-level implementations.
local CLASSES = {
	Clicker   = Clicker,
	Patch     = Patches,
	Processor = Processor,
	Tree      = Trees,
}

local FeedMachines = {}

-- ── Template index ────────────────────────────────────────────────────────────

local index  -- { [feedType] = { template = Instance, class = string } }

local function buildIndex()
	local result = {}
	local root = ReplicatedStorage:WaitForChild("FeedMachines")
	for _, classFolder in ipairs(root:GetChildren()) do
		if classFolder:IsA("Folder") then
			for _, template in ipairs(classFolder:GetChildren()) do
				-- Templates can be BasePart or Model.
				local isPart  = template:IsA("BasePart")
				local isModel = template:IsA("Model")
				if isPart or isModel then
					local feedType = template:GetAttribute(State.Feed.Type) or template.Name
					if result[feedType] then
						warn(string.format(
							"[FeedMachines] Duplicate FeedType %q (in %s)",
							feedType, classFolder.Name
						))
					end
					-- Ensure class + type attributes reflect parent folder /
					-- template name so cloned instances always carry them
					-- (saveFeedState reads FeedType off the attribute).
					if template:GetAttribute(State.Feed.Class) == nil then
						template:SetAttribute(State.Feed.Class, classFolder.Name)
					end
					if template:GetAttribute(State.Feed.Type) == nil then
						template:SetAttribute(State.Feed.Type, feedType)
					end
					result[feedType] = {
						template = template,
						class    = template:GetAttribute(State.Feed.Class),
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

function FeedMachines.AllFeedTypes()
	local out = {}
	for ft in pairs(getIndex()) do out[#out+1] = ft end
	table.sort(out)
	return out
end

-- ── Dispatch ──────────────────────────────────────────────────────────────────

local function feedTypeOf(machine)
	return machine:GetAttribute(State.Feed.Type) or machine.Name
end

local function classOf(machine)
	local cls = machine:GetAttribute(State.Feed.Class)
	if cls then return cls end
	return FeedMachines.GetClass(feedTypeOf(machine))
end

local function impl(machine)
	local cls = classOf(machine)
	return CLASSES[cls], cls
end

function FeedMachines.Setup(machine, plot, owner)
	local mod, name = impl(machine)
	if not mod then
		warn(string.format("[FeedMachines] No implementation for %s", tostring(name)))
		return
	end
	mod.Setup(machine, plot, owner)
	-- Auto-cleanup when the part dies (player picks it up, plot resets, etc.).
	machine.Destroying:Connect(function() FeedMachines.Teardown(machine) end)
end

function FeedMachines.Teardown(machine)
	local mod = impl(machine)
	if mod and mod.Teardown then mod.Teardown(machine) end
end

function FeedMachines.Serialize(machine)
	local mod = impl(machine)
	if mod and mod.Serialize then return mod.Serialize(machine) end
	return nil
end

function FeedMachines.Apply(machine, placement)
	if not placement then return end
	local mod = impl(machine)
	if mod and mod.Apply then mod.Apply(machine, placement) end
end

-- Optional hook a module can implement to vet (and react to) pickup of
-- the machine. Return true to allow the pickup to proceed, false to
-- block. Defaults to true if no module implements it.
function FeedMachines.PrePickup(machine, player)
	local mod = impl(machine)
	if mod and mod.PrePickup then return mod.PrePickup(machine, player) end
	return true
end

function FeedMachines.Interact(machine, player)
	local mod = impl(machine)
	if mod and mod.Interact then return mod.Interact(machine, player) end
	return nil
end

function FeedMachines.HarvestPatchAnchor(anchor, player)
	return Patches.HarvestAnchor(anchor, player)
end

function FeedMachines.PickupTreeGround(ground, player)
	return Trees.PickupGround(ground, player)
end

return FeedMachines
