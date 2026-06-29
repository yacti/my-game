local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

local ATTEMPT_LIMIT = 5
local INIT_FAILED_ATTEMPT_LIMIT = 3
local RETRY_DELAY = 1
local FLOOD_DELAY = 15

local initFailedAttempts = {}

local function playerIsActive(player)
	return player and player:IsA("Player") and player:IsDescendantOf(Players)
end

local function activePlayers(players)
	local result = {}
	for _, player in ipairs(players or {}) do
		if playerIsActive(player) then
			result[#result + 1] = player
		end
	end
	return result
end

local function SafeTeleport(placeId, players, options)
	local attemptIndex = 0
	local success = false
	local result = nil

	repeat
		local candidates = activePlayers(players)
		if #candidates == 0 then
			return false, "no-active-players"
		end

		success, result = pcall(function()
			return TeleportService:TeleportAsync(placeId, candidates, options)
		end)
		attemptIndex += 1
		if not success then
			task.wait(RETRY_DELAY)
		end
	until success or attemptIndex == ATTEMPT_LIMIT

	if not success then
		warn("[SafeTeleport] Teleport failed: " .. tostring(result))
	end

	return success, result
end

local function handleFailedTeleport(player, teleportResult, errorMessage, targetPlaceId, teleportOptions)
	if not playerIsActive(player) then
		return
	end

	local key = player.UserId
	initFailedAttempts[key] = (initFailedAttempts[key] or 0) + 1
	if initFailedAttempts[key] > INIT_FAILED_ATTEMPT_LIMIT then
		warn(string.format(
			"[SafeTeleport] TeleportInitFailed retry limit reached for user %s: %s",
			tostring(key),
			tostring(errorMessage)
		))
		initFailedAttempts[key] = nil
		return
	end

	if teleportResult == Enum.TeleportResult.Flooded then
		task.wait(FLOOD_DELAY)
	elseif teleportResult == Enum.TeleportResult.Failure then
		task.wait(RETRY_DELAY)
	else
		warn(string.format(
			"[SafeTeleport] Invalid teleport for user %s [%s]: %s",
			tostring(key),
			tostring(teleportResult and teleportResult.Name or teleportResult),
			tostring(errorMessage)
		))
		initFailedAttempts[key] = nil
		return
	end

	SafeTeleport(targetPlaceId, { player }, teleportOptions)
end

TeleportService.TeleportInitFailed:Connect(handleFailedTeleport)

Players.PlayerRemoving:Connect(function(player)
	initFailedAttempts[player.UserId] = nil
end)

return SafeTeleport
