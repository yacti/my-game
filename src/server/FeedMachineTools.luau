local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local FeedMachines = require(Server:WaitForChild("feedMachines"))

local Assets = require(ReplicatedStorage.Shared:WaitForChild("Assets"))
local Rarities = require(ReplicatedStorage.Shared:WaitForChild("Rarities"))
local State = require(ReplicatedStorage.Shared:WaitForChild("State"))
local ToolIdentity = require(ReplicatedStorage.Shared:WaitForChild("ToolIdentity"))

local FeedMachineTools = {}

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

function FeedMachineTools.MakeFeedTool(feedType)
	local template = FeedMachines.GetTemplate(feedType)
	if not template then
		warn("[FeedMachines] No feed template for tool: " .. tostring(feedType))
		return nil
	end

	local tool = Assets.WaitFor(Assets.Names.FeedMachineTool):Clone()
	tool.Name = template.Name
	configureHeldToolQuery(tool)
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
