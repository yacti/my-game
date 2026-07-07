local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local FeedMachines = require(Server:WaitForChild("feedMachines"))

local Assets = require(ReplicatedStorage.Shared:WaitForChild("Assets"))
local Rarities = require(ReplicatedStorage.Shared:WaitForChild("Rarities"))
local State = require(ReplicatedStorage.Shared:WaitForChild("State"))
local ToolIdentity = require(ReplicatedStorage.Shared:WaitForChild("ToolIdentity"))

local FeedMachineTools = {}

-- Held feed machine tools show the machine's own model shrunk to hand size;
-- placement still clones the full-size template.
local HELD_MODEL_SCALE = 0.5

local function applyToolRarity(tool, rarity)
	if type(rarity) == "string" and Rarities.IsValid(rarity) then
		tool:SetAttribute(State.Tool.Rarity, rarity)
	end
end

local function configureHeldToolQuery(tool)
	for _, descendant in ipairs(tool:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanQuery = false
		end
	end
end

local function configureBodyPart(part, isHandle)
	part.Anchored   = false
	part.CanCollide = isHandle  -- only the handle collides; sub-parts shouldn't push the player around
	part.CanQuery   = false     -- so the held machine doesn't block ClickDetector raycasts
	part.Massless   = true
end

local function buildToolFromMachineTemplate(template)
	local tool          = Instance.new("Tool")
	tool.RequiresHandle = true

	if template:IsA("BasePart") then
		local handle = template:Clone()
		handle.Name = "Handle"
		handle.Size = handle.Size * HELD_MODEL_SCALE
		configureBodyPart(handle, true)
		handle.Parent = tool
	elseif template:IsA("Model") and template.PrimaryPart then
		local clone = template:Clone()
		clone:ScaleTo(HELD_MODEL_SCALE)
		local handle = clone.PrimaryPart
		handle.Name  = "Handle"
		configureBodyPart(handle, true)

		-- Reparent the Handle to the Tool, then weld every sibling part to
		-- it so the visual moves as one rigid body when held.
		handle.Parent = tool
		for _, p in ipairs(clone:GetDescendants()) do
			if p:IsA("BasePart") then
				configureBodyPart(p, false)
				p.Parent = tool
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = handle
				weld.Part1 = p
				weld.Parent = p
			end
		end
		clone:Destroy()
	else
		tool:Destroy()
		return nil
	end

	return tool
end

function FeedMachineTools.MakeFeedTool(feedType)
	local template = FeedMachines.GetTemplate(feedType)
	if not template then
		warn("[FeedMachines] No feed template for tool: " .. tostring(feedType))
		return nil
	end

	local tool = buildToolFromMachineTemplate(template)
	if not tool then
		warn("[FeedMachines] Template unusable as tool visual (no PrimaryPart?), using placeholder: " .. tostring(feedType))
		tool = Assets.WaitFor(Assets.Names.FeedMachineTool):Clone()
		configureHeldToolQuery(tool)
	end
	tool.Name = template.Name
	tool:SetAttribute(State.Feed.Type, feedType)
	applyToolRarity(tool, template:GetAttribute(State.Feed.Rarity))
	ToolIdentity.AssignGuid(tool)
	return tool
end

function FeedMachineTools.IsFeedTool(item)
	if not (item and item:IsA("Tool")) then
		return false
	end
	local feedType = item:GetAttribute(State.Feed.Type)
	return type(feedType) == "string" and feedType ~= ""
end

return FeedMachineTools
