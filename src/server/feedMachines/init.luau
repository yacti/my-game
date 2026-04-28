-- Registry + dispatcher for FeedMachine templates.
--
-- Templates live at ReplicatedStorage.FeedMachines.<Class>.<TemplateName>.
-- A template can be a BasePart (e.g. Clicker1, Timed1) or a Model (e.g.
-- TimedNew). The template carries:
--   FeedClass  (string, matches parent folder, e.g. "Timed")
--   FeedType   (string, equals template name; what the rest of the codebase keys on)
--   FoodType   (string, foodType produced/accepted, see Shared.Food)
--   plus class- or type-specific tunables (see Shared.State.Feed)
--
-- Two layers of dispatch:
--   TYPES   — keyed by FeedType. Wins when present. Use for variant-specific
--             behavior (e.g. TimedNew growth chain vs. Timed1 spawn loop).
--   CLASSES — keyed by FeedClass. Default for a class when no per-type
--             override is registered. Use when every variant in a class
--             behaves the same.
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

local AppleTree = require(script:WaitForChild("AppleTree"))
local Clicker   = require(script:WaitForChild("Clicker"))
local Processor = require(script:WaitForChild("Processor"))
local Timed1    = require(script:WaitForChild("Timed1"))
local TimedNew  = require(script:WaitForChild("TimedNew"))

-- Class-level fallbacks (used when no TYPES override).
local CLASSES = {
	Clicker   = Clicker,
	Processor = Processor,
}

-- Per-FeedType overrides (preferred). Keys are exact FeedType names.
local TYPES = {
	AppleTree = AppleTree,
	Timed1    = Timed1,
	TimedNew  = TimedNew,
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
	local ft  = feedTypeOf(machine)
	local typ = TYPES[ft]
	if typ then return typ, ft end
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

return FeedMachines
