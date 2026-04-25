-- Clicker FeedMachine: owner clicks the part with the mouse to spawn one
-- piece of food, capped at MaxFood unpicked tools at a time. Cooldown
-- enforced server-side.
--
-- Tunable attributes on the template (see Shared.State.Feed):
--   FoodType       (string, default "Apple")
--   ClickCooldown  (number, default 0.5 seconds)
--   MaxFood        (number, default 5)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local State   = require(ReplicatedStorage.Shared:WaitForChild("State"))
local Spawner = require(script.Parent:WaitForChild("Spawner"))

local Clicker = {}

local state = {} -- [machine] = { owner, plot, lastClick, spawned (set) }

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

function Clicker.Setup(machine, plot, owner)
	local s = { owner = owner, plot = plot, lastClick = 0, spawned = {} }
	state[machine] = s

	local detector = Instance.new("ClickDetector")
	detector.MaxActivationDistance = 24
	detector.Parent = machine

	detector.MouseClick:Connect(function(player)
		if player ~= owner then return end
		if not state[machine] then return end

		local cooldown = machine:GetAttribute(State.Feed.ClickCooldown) or 0.5
		local now = os.clock()
		if now - s.lastClick < cooldown then return end

		local maxFood = machine:GetAttribute(State.Feed.MaxFood) or 5
		if spawnedCount(s) >= maxFood then return end

		local foodType = machine:GetAttribute(State.Feed.FoodType) or "Apple"
		local tool = Spawner.SpawnFoodAbove(machine, foodType)
		if tool then
			s.lastClick = now
			trackSpawned(s, tool)
		end
	end)
end

function Clicker.Teardown(machine)
	local s = state[machine]
	if not s then return end
	state[machine] = nil
	for tool in pairs(s.spawned) do
		if tool.Parent == workspace then tool:Destroy() end
	end
end

return Clicker
