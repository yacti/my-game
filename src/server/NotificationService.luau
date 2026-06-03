local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))

local NotificationService = {}

local PlayerNotification = Remotes.get(Remotes.Names.PlayerNotification)

function NotificationService.Notify(player, payload)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end

	local ok, normalized = RuntimeGuard.Run("NotificationService.Normalize", NotificationConfig.Normalize, payload)
	if not ok then return end
	if not normalized then return end

	RuntimeGuard.Run("NotificationService.FireClient", function()
		PlayerNotification:FireClient(player, normalized)
	end)
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
