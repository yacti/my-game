-- Shared helper used by per-class FeedMachine modules to drop a food Tool
-- onto the floor just above the machine. Lives in its own module so the
-- per-class modules can require it without creating a circular dependency
-- with the registry init.luau.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local State = require(ReplicatedStorage.Shared:WaitForChild("State"))
local Food  = require(ReplicatedStorage.Shared:WaitForChild("Food"))

local Spawner = {}

function Spawner.SpawnFoodAbove(machine, foodType, xpOverride)
	local tool = Food.MakeTool(foodType, xpOverride)
	if not tool then return nil end
	tool:SetAttribute("SourceFeedIndex", machine:GetAttribute(State.Feed.Index))
	tool.Parent = workspace
	tool.Handle.CFrame = CFrame.new(machine.Position + Vector3.new(0, machine.Size.Y / 2 + 1, 0))
	return tool
end

return Spawner
