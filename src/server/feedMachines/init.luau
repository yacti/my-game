-- Registry + dispatcher for FeedMachine classes.
--
-- Templates live at ReplicatedStorage.FeedMachines.<Class>.<TemplateName>
-- where <Class> is one of Clicker / Timed / Processor. Each template part
-- carries:
--   FeedClass  (string, matches parent folder)
--   FeedType   (string, equals template name; what the rest of the codebase keys on)
--   FoodType   (string, foodType produced/accepted, see Shared.Food)
--   plus class-specific tunables (see Shared.State.Feed)
--
-- To add a new behavior: drop a new ModuleScript here named like the class
-- folder, conforming to the API:
--
--   class.Setup(machine, plot, owner)         -- wire interactions; init state
--   class.Teardown(machine)         optional  -- destroy state, default: noop
--   class.Serialize(machine) -> tbl optional  -- extra fields to merge into placement
--   class.Apply(machine, placement) optional  -- restore state from placement
--
-- The registry hooks machine.Destroying to call Teardown automatically.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local State = require(ReplicatedStorage.Shared:WaitForChild("State"))

local Clicker   = require(script:WaitForChild("Clicker"))
local Timed     = require(script:WaitForChild("Timed"))
local Processor = require(script:WaitForChild("Processor"))

local CLASSES = {
	Clicker   = Clicker,
	Timed     = Timed,
	Processor = Processor,
}

local FeedMachines = {}

-- ── Template index ────────────────────────────────────────────────────────────

local index  -- { [feedType] = { template = Part, class = "Clicker" | ... } }

local function buildIndex()
	local result = {}
	local root = ReplicatedStorage:WaitForChild("FeedMachines")
	for _, classFolder in ipairs(root:GetChildren()) do
		if classFolder:IsA("Folder") and CLASSES[classFolder.Name] then
			for _, template in ipairs(classFolder:GetChildren()) do
				if template:IsA("BasePart") then
					local feedType = template:GetAttribute(State.Feed.Type) or template.Name
					if result[feedType] then
						warn(string.format(
							"[FeedMachines] Duplicate FeedType %q (in %s)",
							feedType, classFolder.Name
						))
					end
					-- Ensure class attribute reflects parent folder.
					if template:GetAttribute(State.Feed.Class) == nil then
						template:SetAttribute(State.Feed.Class, classFolder.Name)
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

-- ── Class dispatch ────────────────────────────────────────────────────────────

local function classOf(machine)
	local cls = machine:GetAttribute(State.Feed.Class)
	if cls then return cls end
	local ft = machine:GetAttribute(State.Feed.Type) or machine.Name
	return FeedMachines.GetClass(ft)
end

local function impl(machine)
	local name = classOf(machine)
	return CLASSES[name], name
end

function FeedMachines.Setup(machine, plot, owner)
	local cls, name = impl(machine)
	if not cls then
		warn(string.format("[FeedMachines] No implementation for class %q on %s", tostring(name), machine.Name))
		return
	end
	cls.Setup(machine, plot, owner)
	-- Auto-cleanup when the part dies (player picks it up, plot resets, etc.).
	machine.Destroying:Connect(function() FeedMachines.Teardown(machine) end)
end

function FeedMachines.Teardown(machine)
	local cls = impl(machine)
	if cls and cls.Teardown then cls.Teardown(machine) end
end

function FeedMachines.Serialize(machine)
	local cls = impl(machine)
	if cls and cls.Serialize then return cls.Serialize(machine) end
	return nil
end

function FeedMachines.Apply(machine, placement)
	if not placement then return end
	local cls = impl(machine)
	if cls and cls.Apply then cls.Apply(machine, placement) end
end

return FeedMachines
