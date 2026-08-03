-- Hide Roblox core UI that conflicts with custom gameplay systems.
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
	"PetSkinToolAnimationController",
	"ItemAddedDisplayController",
	"ProximityPromptCustomizer",
	"LocalPrompts",
	"HudController",
	"EventHudController",
	"AdminMessageController",
	"UpdateTimerController",
	"UpdateLogController",
	"HoverOver",
	"RobuxShopController",
	"CashPackShopController",
	"SeedPackShopController",
	"DurianPackController",
	"StarterPackController",
	"StarterPackPromptController",
	"EndlessPackController",
	"GamePassShopController",
	"VipController",
	"JoinBackShowcaseController",
	"JoinGroupRewardController",
	"MediaRewardController",
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
	"AutoRollController",
	"SkipTimeButtonsController",
	"AFKRejoinController",
	"Notifications",
	"PetSkinController",
	"ServerLuckController",
	"AdminLuckController",
	"PetBillboards",
	"PetBillboardFeedEffectController",
	"PetPreloader",
	"CurrencySpendSounds",
	"AnimalAmbientSounds",
	"PetEvolutionEffects",
	"PetAnimations",
	"EditModePetVisibilityController",
	"ToolStatsBillboard",
	"SlotXPBillboard",
	"FoodStealController",
	"GiftController",
	"GrowSkipController",
	"PatchSlotVisuals",
	"AppleTreeSlotVisuals",
	"ScarecrowJumpEffects",
	"MutationVisuals",
	"MutationTooltipController",
	"ThunderstormController",
	"TornadoController",
	"TsunamiController",
	"EarthquakeController",
	"PlotWindController",
	"StormChaserController",
	"BeeEventController",
	"BeeCampController",
	"AlienStandController",
	"PinataController",
	"TimerBillboards",
	"ProcessorVisuals",
	"CloudController",
	"AlienEventController",
	"SprinkleEventController",
	"FeedPlacement",
	"EventRsvpPromptController",
	"TreeClickController",
	"RebirthController",
	"IndexController",
	"LeaderboardController",
	"SettingsController",
	"GridUnlockEffects",
	"AdminPartyPadController",
	"AdminPanelController",
	"RollController",
	"RollBroadcastController",
	"OnboardingController",
	"WorksOfflineController",
}

local function startController(name)
	-- Bounded wait: an unresolvable module must not stall the sequential boot
	-- loop and silently kill every controller after it.
	local moduleScript = ui:WaitForChild(name, 10)
	if not moduleScript then
		warn("[Client] Controller module missing: " .. name)
		return
	end
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
