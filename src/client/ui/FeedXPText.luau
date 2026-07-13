-- Formats the XP stat line for feed machines exactly as the Index menu
-- displays it (trees show "n XP/drop", patches "n XP/s"), including the
-- live PercentageOfBest resolution for dynamic-XP machines. Shared by the
-- Index info panel and shop hover-overs so the two never drift.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local Food = require(Shared:WaitForChild("Food"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local State = require(Shared:WaitForChild("State"))

local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))

local FeedXPText = {}

local player = Players.LocalPlayer
local templateByFeedType = nil
local classByFeedType = nil

local function feedClassOf(template)
	local feedClass = template:GetAttribute(State.Feed.Class)
	if type(feedClass) == "string" and feedClass ~= "" then
		return feedClass
	end
	return template.Parent and template.Parent.Name or nil
end

local function ensureCatalog()
	if templateByFeedType then
		return true
	end
	local machines = Assets.Find(Assets.Names.FeedMachines)
	if not machines then
		return false
	end
	local templates = {}
	local classes = {}
	for _, folder in ipairs(machines:GetChildren()) do
		for _, template in ipairs(folder:GetChildren()) do
			if template:IsA("Model") or template:IsA("BasePart") then
				local feedType = template:GetAttribute(State.Feed.Type)
				if type(feedType) == "string" and feedType ~= "" and not templates[feedType] then
					templates[feedType] = template
					classes[feedType] = feedClassOf(template)
				end
			end
		end
	end
	templateByFeedType = templates
	classByFeedType = classes
	return true
end

local function bestStaticXPForClass(class)
	local plot = PlotResolver.ResolveForPlayer(player)
	if not plot then
		return nil
	end
	local best = nil
	for _, child in ipairs(plot:GetChildren()) do
		if (child:IsA("Model") or child:IsA("BasePart"))
			and type(child:GetAttribute(State.Feed.Type)) == "string"
			and child:GetAttribute(State.Feed.Index) ~= nil
			and child:GetAttribute(State.Seed.Phase) ~= "GrowingSeed"
			and child:GetAttribute(State.Feed.PercentageOfBest) == nil then
			local childClass = child:GetAttribute(State.Feed.Class)
			if type(childClass) ~= "string" or childClass == "" then
				childClass = classByFeedType and classByFeedType[child:GetAttribute(State.Feed.Type)] or nil
			end
			if childClass == class then
				local xp = tonumber(child:GetAttribute(State.Feed.XP)) or 1
				if not best or xp > best then
					best = xp
				end
			end
		end
	end
	return best
end

-- entry: { class, pct, foodDrop, xp } as built by EntryForFeedType or the
-- Index catalog. Dynamic (pct) entries resolve against the player's plot on
-- every call, mirroring FeedMachines.RecomputeDynamicXP:
-- resolved = max(pct x best same-class static machine XP, 1).
function FeedXPText.ForEntry(entry)
	local resolved
	if entry.pct then
		ensureCatalog()
		resolved = math.max(entry.pct * (bestStaticXPForClass(entry.class) or 0), 1)
	else
		resolved = entry.xp or 1
	end
	if entry.class == "Tree" then
		-- Tree XP attribute is a per-drop multiplier on the food's own XP.
		return NumberFormatter.XP(Food.BaseXP(entry.foodDrop) * resolved, " XP/drop")
	end
	return NumberFormatter.XP(resolved, " XP/s")
end

function FeedXPText.EntryForFeedType(feedType)
	if type(feedType) ~= "string" or feedType == "" or not ensureCatalog() then
		return nil
	end
	local template = templateByFeedType[feedType]
	if not template then
		return nil
	end
	return {
		class = classByFeedType[feedType],
		pct = tonumber(template:GetAttribute(State.Feed.PercentageOfBest)),
		foodDrop = template:GetAttribute(State.Feed.FoodDrop),
		xp = tonumber(template:GetAttribute(State.Feed.XP)),
	}
end

function FeedXPText.ForFeedType(feedType)
	local entry = FeedXPText.EntryForFeedType(feedType)
	return entry and FeedXPText.ForEntry(entry) or nil
end

function FeedXPText.ForSeed(seedId)
	return FeedXPText.ForFeedType(Seeds.FeedTypeFor(seedId))
end

return FeedXPText
