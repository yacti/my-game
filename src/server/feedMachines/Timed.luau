-- Timed FeedMachine: spawns a piece of food every SpawnInterval seconds,
-- capped at MaxFood unpicked tools at a time. Per-machine spawn loop;
-- exits when the machine is torn down (state entry cleared).
--
-- Tunable attributes on the template (see Shared.State.Feed):
--   FoodType       (string, default "Apple")
--   SpawnInterval  (number, default 5 seconds)
--   MaxFood        (number, default 5)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local State   = require(ReplicatedStorage.Shared:WaitForChild("State"))
local Spawner = require(script.Parent:WaitForChild("Spawner"))

local Timed = {}

local state = {} -- [machine] = { owner, plot, spawned (set) }

local function spawnedCount(s)
	local n = 0
	for _ in pairs(s.spawned) do n += 1 end
	return n
end

local function trackSpawned(s, tool)
	s.spawned[tool] = true
	local conn
	conn = tool.AncestryChanged:Connect(function(_, parent)
		if parent ~= workspace then
			s.spawned[tool] = nil
			conn:Disconnect()
		end
	end)
end

function Timed.Setup(machine, plot, owner)
	local s = { owner = owner, plot = plot, spawned = {} }
	state[machine] = s

	task.spawn(function()
		while state[machine] == s do
			local interval = machine:GetAttribute(State.Feed.SpawnInterval) or 5
			task.wait(interval)
			if state[machine] ~= s then return end

			local maxFood = machine:GetAttribute(State.Feed.MaxFood) or 5
			if spawnedCount(s) >= maxFood then continue end

			local foodType = machine:GetAttribute(State.Feed.FoodType) or "Apple"
			local tool = Spawner.SpawnFoodAbove(machine, foodType)
			if tool then trackSpawned(s, tool) end
		end
	end)
end

function Timed.Teardown(machine)
	local s = state[machine]
	if not s then return end
	state[machine] = nil
	for tool in pairs(s.spawned) do
		if tool.Parent == workspace then tool:Destroy() end
	end
end

return Timed
