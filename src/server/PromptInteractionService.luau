local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Interactions = require(Shared:WaitForChild("Interactions"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local TelemetryService = require(script.Parent:WaitForChild("TelemetryService"))

local PromptInteractionService = {}

local DEFAULT_RATE_SECONDS = 0.12

local function userKey(player)
	return player and player.UserId or nil
end

local function consumeRateLimit(map, player, interval)
	local key = userKey(player)
	if key == nil then return false end
	local now = os.clock()
	local previous = map[key] or 0
	if now - previous < interval then return false end
	map[key] = now
	return true
end

local function withPlayerLock(map, player, callback)
	local key = userKey(player)
	if key == nil or map[key] then return end
	map[key] = true
	RuntimeGuard.Run("PromptInteractionService.Handler", callback)
	map[key] = nil
end

function PromptInteractionService.Start(config)
	config = config or {}
	local handlers = config.handlers or {}
	local getContext = config.getContext
	local afterInteraction = config.afterInteraction
	local requireTargetInPlot = config.requireTargetInPlot ~= false
	local rateSeconds = tonumber(config.rateSeconds) or DEFAULT_RATE_SECONDS
	local lastFire = {}
	local locks = {}

	RuntimeGuard.Connect(Players.PlayerRemoving, "PromptInteractionService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key == nil then return end
		lastFire[key] = nil
		locks[key] = nil
	end)

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.PromptInteract).OnServerEvent, "PromptInteractionService.PromptInteract", function(player, action, target)
		if type(action) ~= "string" or typeof(target) ~= "Instance" then return end
		if not consumeRateLimit(lastFire, player, rateSeconds) then return end
		if not Interactions.IsAction(action) then
			TelemetryService.Warn("prompt_interact_rejected", TelemetryService.ForPlayer(player, {
				reason = "invalid-action",
				action = action,
			}))
			return
		end
		if type(getContext) ~= "function" then return end

		local ok, plot, profile = RuntimeGuard.Run("PromptInteractionService.GetContext", getContext, player)
		if not ok then return end
		if not plot or not profile then return end
		if requireTargetInPlot and not target:IsDescendantOf(plot) then
			TelemetryService.Warn("prompt_interact_rejected", TelemetryService.ForPlayer(player, {
				reason = "wrong-plot",
				action = action,
				target = target,
				plot = plot,
			}))
			return
		end

		withPlayerLock(locks, player, function()
			local handler = handlers[action]
			if handler then
				handler(player, target, plot, profile)
			end
		end)

		if type(afterInteraction) == "function" then
			RuntimeGuard.Run("PromptInteractionService.AfterInteraction", afterInteraction, player, plot, profile)
		end
	end)
end

return PromptInteractionService
