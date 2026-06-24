local Players = game:GetService("Players")

local Server = script.Parent
local OfflineProgressService = require(Server:WaitForChild("OfflineProgressService"))
local OnboardingService = require(Server:WaitForChild("OnboardingService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService = require(Server:WaitForChild("PlotService"))

local EventEligibility = {}

function EventEligibility.Context(player)
	if not (player and player.Parent == Players) then
		return nil, "not-in-game"
	end

	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		return nil, "profile-not-loaded"
	end
	if OnboardingService.IsActive(profile) then
		return nil, "onboarding"
	end
	if OfflineProgressService.IsPending(player) then
		return nil, "offline-progress-pending"
	end

	local plot = PlotService.GetPlayerPlot(player)
	if not plot then
		return nil, "no-plot"
	end

	return {
		player = player,
		profile = profile,
		plot = plot,
	}, "ok"
end

function EventEligibility.IsEligible(player)
	local context, code = EventEligibility.Context(player)
	return context ~= nil, code, context
end

function EventEligibility.IsEligibleForPlot(player, plot)
	local context, code = EventEligibility.Context(player)
	if not context then
		return false, code
	end
	if context.plot ~= plot then
		return false, "plot-changed"
	end
	return true, "ok", context
end

return EventEligibility
