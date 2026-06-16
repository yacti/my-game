-- Hide Roblox's default backpack so Satchel is the only inventory UI.
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local function requireReplicaClient()
	local replicaShared = ReplicatedStorage:WaitForChild("ReplicaShared", 10)
	assert(replicaShared and replicaShared:IsA("Folder"), "Missing ReplicatedStorage.ReplicaShared Folder")
	local moduleScript = ReplicatedStorage:WaitForChild("ReplicaClient", 10)
	assert(moduleScript and moduleScript:IsA("ModuleScript"), "Missing ReplicatedStorage.ReplicaClient ModuleScript")
	return require(moduleScript)
end

local Replica = requireReplicaClient()

RuntimeGuard.Run("Client.DisableBackpackCoreGui", function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)

local ui = script:WaitForChild("ui")

local CONTROLLERS = {
	"PlayerStateStore",
	"SatchelController",
	"ItemAddedDisplayController",
	"ProximityPromptCustomizer",
	"LocalPrompts",
	"HudController",
	"UpdateTimerController",
	"HoverOver",
	"RobuxShopController",
	"CashPackShopController",
	"SeedPackShopController",
	"StarterPackController",
	"GamePassShopController",
	"VipController",
	"JoinBackShowcaseController",
	"MusicPlaylistController",
	"BirdBackingTrackController",
	"AutoPromptButtonController",
	"GearShopController",
	"CosmeticShopController",
	"YesNoWarning",
	"FeedEditController",
	"ShovelController",
	"RollLuckController",
	"RollDropAreaController",
	"Notifications",
	"ServerLuckController",
	"PetBillboards",
	"PetPreloader",
	"CurrencySpendSounds",
	"AnimalAmbientSounds",
	"PetEvolutionEffects",
	"PetAnimations",
	"ToolStatsBillboard",
	"SlotXPBillboard",
	"FoodStealController",
	"GrowSkipController",
	"PatchSlotVisuals",
	"AppleTreeSlotVisuals",
	"TimerBillboards",
	"ProcessorVisuals",
	"CloudController",
	"FeedPlacement",
	"TreeClickController",
	"RebirthController",
	"GridUnlockEffects",
	"RollController",
	"OnboardingController",
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

-- Request after controllers start so future Replica listeners can register first.
RuntimeGuard.Run("Client.ReplicaRequestData", function()
	Replica.RequestData()
end)
