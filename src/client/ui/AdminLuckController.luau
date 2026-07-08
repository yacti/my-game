-- HUD badge for the global admin luck boost (HUD.Buffs.AdminLuck). Reads the
-- ReplicatedStorage attributes published by AdminLuckService; visible only
-- while a boost is active. Presentation mirrors the ServerLuck buff.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local AdminLuckController = {}

local HUD_NAME = "HUD"
local HUD_WAIT_SECONDS = 10
local BUFF_NAME = "AdminLuck"
local TIMER_UPDATE_SECONDS = 0.25

local function child(parent, name, className)
	local found = parent and parent:FindFirstChild(name)
	if found and (not className or found:IsA(className)) then
		return found
	end
	return nil
end

local function findHudBuff(playerGui)
	local hud = playerGui:WaitForChild(HUD_NAME, HUD_WAIT_SECONDS)
	if not hud then
		warn("[AdminLuckController] Missing PlayerGui.HUD")
		return nil
	end
	local buffs = hud:FindFirstChild("Buffs")
	local buff = buffs and buffs:FindFirstChild(BUFF_NAME)
	if buff and buff:IsA("GuiObject") then
		return buff, hud
	end
	warn("[AdminLuckController] Missing HUD.Buffs.AdminLuck")
	return nil, hud
end

local function formatTimer(seconds)
	seconds = math.max(math.ceil(tonumber(seconds) or 0), 0)
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	local remainder = seconds % 60
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, remainder)
	end
	return string.format("%02d:%02d", minutes, remainder)
end

local function boostState()
	local currentTime = Workspace:GetServerTimeNow()
	local multiplier = tonumber(ReplicatedStorage:GetAttribute(State.AdminLuck.Multiplier)) or 1
	local endsAt = tonumber(ReplicatedStorage:GetAttribute(State.AdminLuck.EndsAt)) or 0
	local active = multiplier > 1 and endsAt > currentTime
	return {
		active = active,
		multiplier = math.max(math.floor(multiplier), 1),
		remaining = active and math.max(endsAt - currentTime, 0) or 0,
	}
end

function AdminLuckController.start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local buff, hud = findHudBuff(playerGui)
	if not buff then
		return
	end
	local timerLabel = child(buff, "Timer", "TextLabel")
	local multiplierLabel = child(buff, "Multiplier", "TextLabel")
	if not (timerLabel and multiplierLabel) then
		warn("[AdminLuckController] HUD.Buffs.AdminLuck is missing Timer or Multiplier")
		buff.Visible = false
		return
	end

	local function render()
		local state = boostState()
		buff.Visible = state.active
		if not state.active then
			return
		end
		UiEffects.SetTextStack(timerLabel, formatTimer(state.remaining))
		UiEffects.SetTextStack(multiplierLabel, tostring(state.multiplier) .. "x")
	end

	RuntimeGuard.Connect(ReplicatedStorage:GetAttributeChangedSignal(State.AdminLuck.Multiplier), "AdminLuckController.MultiplierChanged", render)
	RuntimeGuard.Connect(ReplicatedStorage:GetAttributeChangedSignal(State.AdminLuck.EndsAt), "AdminLuckController.EndsAtChanged", render)

	local elapsed = 0
	local heartbeatConnection
	heartbeatConnection = RuntimeGuard.Connect(RunService.Heartbeat, "AdminLuckController.Heartbeat", function(deltaTime)
		elapsed += deltaTime
		if elapsed < TIMER_UPDATE_SECONDS then
			return
		end
		elapsed = 0
		render()
	end)
	if hud then
		RuntimeGuard.Connect(hud.Destroying, "AdminLuckController.HudDestroying", function()
			if heartbeatConnection then
				heartbeatConnection:Disconnect()
				heartbeatConnection = nil
			end
		end)
	end

	render()
end

return AdminLuckController
