local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))

local NotificationService = {}

local PlayerNotification = Remotes.get(Remotes.Names.PlayerNotification)

function NotificationService.Notify(player, payload)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end

	local normalized = NotificationConfig.Normalize(payload)
	if not normalized then return end

	PlayerNotification:FireClient(player, normalized)
end

function NotificationService.Info(player, text)
	NotificationService.Notify(player, {
		kind = NotificationConfig.Kinds.Info,
		text = text,
	})
end

function NotificationService.Success(player, text)
	NotificationService.Notify(player, {
		kind = NotificationConfig.Kinds.Success,
		text = text,
	})
end

function NotificationService.Error(player, text)
	NotificationService.Notify(player, {
		kind = NotificationConfig.Kinds.Error,
		text = text,
	})
end

return NotificationService
