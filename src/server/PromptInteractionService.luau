local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Interactions = require(Shared:WaitForChild("Interactions"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local PromptInteractionService = {}

local DEFAULT_RATE_SECONDS = 0.12

local function consumeRateLimit(map, player, interval)
	local now = os.clock()
	local previous = map[player] or 0
	if now - previous < interval then return false end
	map[player] = now
	return true
end

local function withPlayerLock(map, player, callback)
	if map[player] then return end
	map[player] = true
	local ok, err = pcall(callback)
	map[player] = nil
	if not ok then
		warn(err)
	end
end

function PromptInteractionService.Start(config)
	config = config or {}
	local handlers = config.handlers or {}
	local getContext = config.getContext
	local afterInteraction = config.afterInteraction
	local rateSeconds = tonumber(config.rateSeconds) or DEFAULT_RATE_SECONDS
	local lastFire = {}
	local locks = {}

	Remotes.get(Remotes.Names.PromptInteract).OnServerEvent:Connect(function(player, action, target)
		if type(action) ~= "string" or typeof(target) ~= "Instance" then return end
		if not Interactions.IsAction(action) then return end
		if not consumeRateLimit(lastFire, player, rateSeconds) then return end
		if type(getContext) ~= "function" then return end

		local plot, profile = getContext(player)
		if not plot or not profile then return end

		withPlayerLock(locks, player, function()
			local handler = handlers[action]
			if handler then
				handler(player, target, plot, profile)
			end
		end)

		if type(afterInteraction) == "function" then
			afterInteraction(player, plot, profile)
		end
	end)
end

return PromptInteractionService
