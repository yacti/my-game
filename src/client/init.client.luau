-- Hide Roblox's default backpack so Satchel is the only inventory UI.
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

RuntimeGuard.Run("Client.DisableBackpackCoreGui", function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)

local ui = script:WaitForChild("ui")

local CONTROLLERS = {
	"LocalPrompts",
	"HudController",
	"YesNoWarning",
	"FeedEditController",
	"ShovelController",
	"RollLuckController",
	"RollDropAreaController",
	"Notifications",
	"PetBillboards",
	"PetPreloader",
	"PetEvolutionEffects",
	"PetAnimations",
	"ToolStatsBillboard",
	"SlotXPBillboard",
	"AppleTreeSlotVisuals",
	"GrowingSeedBillboards",
	"ProcessorVisuals",
	"CloudController",
	"FeedPlacement",
	"RebirthController",
	"GridUnlockEffects",
	"RollController",
}

local function startController(name)
	local moduleScript = ui:WaitForChild(name)
	RuntimeGuard.Run("Client.StartController." .. name, function()
		local controller = require(moduleScript)
		if type(controller.start) == "function" then
			controller.start()
		else
			warn("[Client] Controller has no start function: " .. name)
		end
	end)
end

for _, controllerName in ipairs(CONTROLLERS) do
	startController(controllerName)
end
