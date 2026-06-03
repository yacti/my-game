local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local FeedMachines = require(Server:WaitForChild("feedMachines"))

local State = require(ReplicatedStorage.Shared:WaitForChild("State"))
local ToolIdentity = require(ReplicatedStorage.Shared:WaitForChild("ToolIdentity"))

local FeedMachineTools = {}

function FeedMachineTools.MakeFeedTool(feedType)
	local template = FeedMachines.GetTemplate(feedType)
	if not template then
		warn("[FeedMachines] No feed template for tool: " .. tostring(feedType))
		return nil
	end

	local tool = ReplicatedStorage:WaitForChild("FeedMachineTool"):Clone()
	tool.Name = template.Name
	tool:SetAttribute(State.Feed.Type, feedType)
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
