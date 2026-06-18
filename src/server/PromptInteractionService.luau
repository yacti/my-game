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

local function acquirePlayerLock(map, player)
	local key = userKey(player)
	if key == nil or map[key] then
		return false
	end
	map[key] = true
	return true, key
end

local function releasePlayerLock(map, key)
	if key ~= nil then
		map[key] = nil
	end
end

local function actionSetFromList(actions)
	local set = {}
	if type(actions) ~= "table" then
		return set
	end
	for key, value in pairs(actions) do
		if type(key) == "string" and value == true then
			set[key] = true
		elseif type(value) == "string" then
			set[value] = true
		end
	end
	return set
end

function PromptInteractionService.Start(config)
	config = config or {}
	local handlers = config.handlers or {}
	local getContext = config.getContext
	local afterInteraction = config.afterInteraction
	local requireTargetInPlot = config.requireTargetInPlot ~= false
	local rateSeconds = tonumber(config.rateSeconds) or DEFAULT_RATE_SECONDS
	local familyActionRateSeconds = tonumber(config.familyActionRateSeconds)
	local familyActions = actionSetFromList(config.familyActions)
	local lastFire = {}
	local lastFamilyAction = {}
	local locks = {}

	RuntimeGuard.Connect(Players.PlayerRemoving, "PromptInteractionService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key == nil then return end
		lastFire[key] = nil
		lastFamilyAction[key] = nil
		locks[key] = nil
	end)

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.PromptInteract).OnServerEvent, "PromptInteractionService.PromptInteract", function(player, action, target, isAutoHold)
		if type(action) ~= "string" or typeof(target) ~= "Instance" then return end
		if not consumeRateLimit(lastFire, player, rateSeconds) then
			TelemetryService.Record("prompt_interact_rejected", TelemetryService.ForPlayer(player, {
				reason = "rate-limited",
				action = action,
			}))
			return
		end
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

		local handler = handlers[action]
		if type(handler) ~= "function" then
			TelemetryService.Warn("prompt_interact_rejected", TelemetryService.ForPlayer(player, {
				reason = "no-handler",
				action = action,
			}))
			return
		end

		local acquired, lockKey = acquirePlayerLock(locks, player)
		if not acquired then
			TelemetryService.Record("prompt_interact_rejected", TelemetryService.ForPlayer(player, {
				reason = "lock-busy",
				action = action,
				isAutoHold = isAutoHold == true,
			}))
			return
		end

		local handlerResult = nil
		local handlerRan = false
		local shouldReleaseLock = true
		local function release()
			if shouldReleaseLock then
				shouldReleaseLock = false
				releasePlayerLock(locks, lockKey)
			end
		end

		if familyActionRateSeconds
			and familyActions[action] == true
			and not consumeRateLimit(lastFamilyAction, player, familyActionRateSeconds) then
			TelemetryService.Record("prompt_interact_rejected", TelemetryService.ForPlayer(player, {
				reason = "family-rate-limited",
				action = action,
				isAutoHold = isAutoHold == true,
			}))
			release()
			return
		end

		local handlerOk = RuntimeGuard.Run("PromptInteractionService.Handler", function()
			handlerRan = true
			handlerResult = handler(player, target, plot, profile)
		end)
		release()

		if handlerRan and handlerOk and type(afterInteraction) == "function" then
			RuntimeGuard.Run("PromptInteractionService.AfterInteraction", afterInteraction, player, plot, profile, action, target, handlerResult)
		end
	end)
end

return PromptInteractionService
