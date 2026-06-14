local Players = game:GetService("Players")

local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))

local VipController = {}

local HUD_NAME = "HUD"
local HUD_WAIT_SECONDS = 10

local player = Players.LocalPlayer

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
		warn("[VipController] Missing PlayerGui.HUD")
		return nil
	end
	local buffs = hud:FindFirstChild("Buffs")
	local vip = buffs and buffs:FindFirstChild("VIP")
	if vip and vip:IsA("GuiObject") then
		return vip
	end
	warn("[VipController] Missing HUD.Buffs.VIP")
	return nil
end

local function bindHudBuff(buff)
	local icon = child(buff, "Icon", "ImageLabel")
	if not icon then
		warn("[VipController] HUD.Buffs.VIP is missing Icon")
		buff.Visible = false
		return nil
	end

	local function render()
		buff.Visible = PlayerStateStore.Get(PlayerStateStore.Fields.VipOwned) == true
	end
	return render
end

function VipController.start()
	local renderers = {}
	local renderAll
	renderAll = function()
		for _, render in ipairs(renderers) do
			render()
		end
	end

	local playerGui = player:WaitForChild("PlayerGui")
	local hudBuff = findHudBuff(playerGui)
	if hudBuff then
		local renderHud = bindHudBuff(hudBuff)
		if renderHud then
			renderers[#renderers + 1] = renderHud
		end
	end

	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, renderAll)
	PlayerStateStore.Observe(PlayerStateStore.Fields.VipOwned, renderAll)
	PlayerStateStore.Observe(PlayerStateStore.Fields.GamePassOwnership, renderAll)
	renderAll()
end

return VipController
