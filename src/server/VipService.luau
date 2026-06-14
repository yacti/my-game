local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local GamePassService = require(Server:WaitForChild("GamePassService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))

local VipService = {}

function VipService.RefreshOwnership(player)
	local ownership, code = GamePassService.RefreshOwnership(player, {
		PassKey = ShopBalance.GamePassKeys.VIP,
	})
	return type(ownership) == "table" and ownership[ShopBalance.GamePassKeys.VIP] == true or false, code
end

function VipService.OwnsVip(player)
	return GamePassService.Owns(player, ShopBalance.GamePassKeys.VIP)
end

function VipService.PetCashEarnRate(player)
	local vip = ShopBalance.GetVIP()
	if not VipService.OwnsVip(player) then
		return 1
	end
	return tonumber(vip and vip.PetCashEarnRate) or 1
end

function VipService.LuckBonusPercent(player)
	return VipService.OwnsVip(player) and math.max(tonumber((ShopBalance.GetVIP() or {}).LuckBonusPercent) or 0, 0) or 0
end

function VipService.Start()
	GamePassService.Start()
end

return VipService
