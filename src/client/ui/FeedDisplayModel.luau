-- Builds viewport display models for feed machines: the machine template with
-- its produced food pinned onto the BaseFood slot anchors (mirrors
-- Trees.spawnSlotVisual / Patches.makeSlotAnchor), with placeholder/utility
-- parts stripped. Build() serves the Index menu (trees and patches alike);
-- SeedPreview() serves seed reward cards, where tree seeds show the fruited
-- tree but patch seeds show just the food.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
local GrowingVisuals = require(Shared:WaitForChild("GrowingVisuals"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local State = require(Shared:WaitForChild("State"))

local FeedDisplayModel = {}

-- Fruited trees read smaller than bare fruit at the same normalized bounds,
-- so tree previews get a closer camera.
local TREE_PREVIEW_ZOOM_MULTIPLIER = 1.25

-- The house style for an item shown as a reward on a card: normalized to a
-- consistent size, lit hard and saturated so it reads at card scale against a
-- busy panel. SeedPackShop, EndlessPack, DurianPack and StarterPack each grew
-- their own copy of these exact numbers; new callers should use this one rather
-- than adding a fifth.
--
-- Treat as read-only. Pass it as ViewportPreview.Render's options directly, or
-- as SeedPreview's baseOptions (which copies before adding its tree zoom).
FeedDisplayModel.REWARD_PREVIEW_OPTIONS = {
	targetMaxDimension = 6,
	zoom = 1.8,
	colorSaturation = 2.5,
	colorBrightness = 1.55,
	lightColor = Color3.fromRGB(255, 255, 255),
}

local modelsBySeedId = {}

local function disableBakedBillboards(instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BillboardGui") then
			descendant.Enabled = false
		end
	end
end

local function feedClassOf(template)
	local feedClass = template:GetAttribute(State.Feed.Class)
	if type(feedClass) == "string" and feedClass ~= "" then
		return feedClass
	end
	return template.Parent and template.Parent.Name or nil
end

function FeedDisplayModel.Build(template)
	if not (template and (template:IsA("Model") or template:IsA("BasePart"))) then
		return nil
	end

	local class = feedClassOf(template)
	local foodDrop = template:GetAttribute(State.Feed.FoodDrop)
	local foodTemplate = type(foodDrop) == "string" and Food.GetTemplate(foodDrop) or nil
	local clone = template:Clone()

	local slots = {}
	local removals = {}
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("BasePart") then
			if class == "Tree" and descendant.Name:match("^BaseFood%d+$") then
				slots[#slots + 1] = descendant.CFrame
				removals[#removals + 1] = descendant
			elseif class == "Tree" and descendant.Name:match("^BaseFoodGround%d*$") then
				removals[#removals + 1] = descendant
			elseif class == "Patch" and descendant.Name == "BaseFood" then
				-- Patch food templates author their pivot at the bottom
				-- contact point; anchor at the slot's bottom face.
				slots[#slots + 1] = descendant.CFrame * CFrame.new(0, -descendant.Size.Y / 2, 0)
				removals[#removals + 1] = descendant
			elseif descendant.Name == "EditSelectionHitbox" then
				removals[#removals + 1] = descendant
			end
		end
	end

	for _, slotCFrame in ipairs(slots) do
		if foodTemplate then
			local food = foodTemplate:Clone()
			disableBakedBillboards(food)
			if food:IsA("BasePart") then
				food.CFrame = slotCFrame
			elseif food:IsA("Model") then
				food:PivotTo(slotCFrame)
			end
			food.Parent = clone
		end
	end
	for _, part in ipairs(removals) do
		part:Destroy()
	end
	return clone
end

local function withZoomMultiplier(options, multiplier)
	local merged = {}
	if type(options) == "table" then
		for key, value in pairs(options) do
			merged[key] = value
		end
	end
	merged.zoom = (tonumber(merged.zoom) or 1) * multiplier
	return merged
end

-- Preview template + viewport options for a seed reward. Tree seeds show the
-- fruited tree; patch seeds show just the food; both fall back to the seed
-- model when a link is missing (e.g. a seed whose machine doesn't exist yet).
-- Built tree models are cached; callers must not mutate or destroy them
-- (ViewportPreview.Render clones its template).
function FeedDisplayModel.SeedPreview(seedId, baseOptions)
	if type(seedId) ~= "string" or seedId == "" then
		return nil, baseOptions
	end

	local feedType = Seeds.FeedTypeFor(seedId)
	local machine = feedType and GrowingVisuals.FeedTemplateFor(feedType)
	if machine and GrowingVisuals.FeedClassFor(feedType) == "Tree" then
		local model = modelsBySeedId[seedId]
		if not model then
			model = FeedDisplayModel.Build(machine)
			modelsBySeedId[seedId] = model
		end
		return model, withZoomMultiplier(baseOptions, TREE_PREVIEW_ZOOM_MULTIPLIER)
	end

	local foodDrop = machine and machine:GetAttribute(State.Feed.FoodDrop)
	local food = type(foodDrop) == "string" and Food.GetTemplate(foodDrop) or nil
	return food or Seeds.GetTemplate(seedId), baseOptions
end

return FeedDisplayModel
