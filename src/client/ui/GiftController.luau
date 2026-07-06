local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Cosmetics = require(Shared:WaitForChild("Cosmetics"))
local Food = require(Shared:WaitForChild("Food"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local Shovel = require(Shared:WaitForChild("Shovel"))
local State = require(Shared:WaitForChild("State"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local LocalPrompts = require(script.Parent:WaitForChild("LocalPrompts"))
local NotificationUi = require(script.Parent:WaitForChild("Notifications"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local YesNoWarning = require(script.Parent:WaitForChild("YesNoWarning"))

local GiftController = {}

local PROMPT_KIND = "Gift"
local PROMPT_DISTANCE = 10
local PROMPT_ATTACHMENT_NAME = "__LocalPrompt_GiftAttachment"
local RESULT_TIMEOUT_SECONDS = 10

-- recipient-inventory-full is absent on purpose: the server already sends
-- the giver an Error notification for it.
local FAILURE_MESSAGES = {
	["rate-limited"] = "Please wait a moment before gifting again",
	["busy"] = "Please wait a moment before gifting again",
	["too-far"] = "Too far away to gift",
	["not-holding"] = "You are no longer holding that item",
	["onboarding"] = "Finish the tutorial before gifting",
	["recipient-onboarding"] = "That player hasn't finished the tutorial yet",
	["recipient-gone"] = "That player left the game",
	["recipient-not-ready"] = "That player can't receive gifts right now",
	["recipient-busy"] = "That player can't receive gifts right now",
	["recipient-no-character"] = "That player can't receive gifts right now",
	["recipient-no-plot"] = "That player can't receive gifts right now",
}
local DEFAULT_FAILURE_MESSAGE = "Could not complete the gift"

local player = Players.LocalPlayer
local requestRemote = Remotes.get(Remotes.Names.GiftRequest)
local resultRemote = Remotes.get(Remotes.Names.GiftResult)

local tracked = {}
local playerConnections = {}
local nextRequestId = 0
local pendingRequestId = nil
local promptOpen = false
local promptToken = 0

local function isGiftableTool(tool)
	if not (tool and tool:IsA("Tool")) then
		return false
	end
	if ToolIdentity.GuidOf(tool) == nil then
		return false
	end
	if Shovel.IsTool(tool) then
		return false
	end
	local feedType = tool:GetAttribute(State.Feed.Type)
	if type(feedType) == "string" and feedType ~= "" then
		return false
	end
	if Food.IsFood(tool) then
		return true
	end
	local seedId = tool:GetAttribute(State.Seed.Id)
	if type(seedId) == "string" and Seeds.GetTemplate(seedId) ~= nil then
		return true
	end
	local cosmeticId = tool:GetAttribute(State.Cosmetic.Id)
	if type(cosmeticId) == "string" and Cosmetics.GetTemplate(cosmeticId) ~= nil then
		return true
	end
	return false
end

local function giftableEquippedTool()
	local character = player.Character
	if not character then
		return nil
	end
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") and isGiftableTool(child) then
			return child
		end
	end
	return nil
end

-- Fail closed: no replicated onboarding state hides the prompt.
local function selfOnboardingComplete()
	local state = PlayerStateStore.Get(PlayerStateStore.Fields.Onboarding)
	return type(state) == "table"
		and not Onboarding.IsActive(Onboarding.SanitizeState(state, Onboarding.CompleteState()).Stage)
end

local function isAvailable(other)
	if pendingRequestId ~= nil or promptOpen then
		return false
	end
	if other.Parent ~= Players then
		return false
	end
	if PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true then
		return false
	end
	if player:GetAttribute(State.Player.OfflineProgressPending) == true then
		return false
	end
	if not selfOnboardingComplete() then
		return false
	end
	-- Best-effort UX for the target's tutorial state; the server rejects
	-- from both profiles regardless.
	if other:GetAttribute(State.Player.OnboardingActive) == true then
		return false
	end
	local character = other.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	return giftableEquippedTool() ~= nil
end

local function cleanupCharacter(other)
	local record = tracked[other]
	if not record then
		return
	end
	tracked[other] = nil
	if record.unregister then
		record.unregister()
	end
	for _, connection in ipairs(record.connections) do
		connection:Disconnect()
	end
	if record.prompt then
		record.prompt:Destroy()
	end
	if record.attachment and record.attachment.Parent then
		record.attachment:Destroy()
	end
end

local function sendRequest(other, toolGuid)
	nextRequestId += 1
	pendingRequestId = nextRequestId
	local requestId = nextRequestId
	requestRemote:FireServer(requestId, other.UserId, toolGuid)
	-- The server answers every request; this only unsticks the prompt if
	-- the result is lost (e.g. teleport race).
	task.delay(RESULT_TIMEOUT_SECONDS, function()
		if pendingRequestId == requestId then
			pendingRequestId = nil
		end
	end)
end

local function onPromptTriggered(other)
	if pendingRequestId ~= nil or promptOpen then
		return
	end
	if not isAvailable(other) then
		return
	end
	local tool = giftableEquippedTool()
	local toolGuid = ToolIdentity.GuidOf(tool)
	if not toolGuid then
		return
	end

	promptToken += 1
	local token = promptToken
	promptOpen = true
	local itemText = tool.Name
	if itemText:sub(-1) ~= "?" then
		itemText ..= "?"
	end
	local opened = YesNoWarning.Prompt({
		title = "Gift Item?",
		question = string.format("Are you sure you want to gift %s", other.DisplayName),
		itemText = itemText,
		itemRarity = tool:GetAttribute(State.Tool.Rarity),
		yesText = "Yes",
		noText = "No",
	}, function(confirmed)
		if token ~= promptToken then
			return
		end
		promptOpen = false
		if not confirmed or other.Parent ~= Players then
			return
		end
		-- The giver may have swapped tools while the dialog was open; only
		-- send if the exact confirmed tool is still equipped.
		local currentTool = giftableEquippedTool()
		if not currentTool or ToolIdentity.GuidOf(currentTool) ~= toolGuid then
			return
		end
		sendRequest(other, toolGuid)
	end)
	if not opened then
		promptOpen = false
	end
end

local function bindCharacter(other, character)
	cleanupCharacter(other)
	RuntimeGuard.Spawn("GiftController.BindCharacter", function()
		local root = character:WaitForChild("HumanoidRootPart", 10)
		if not root then
			warn("[GiftController] No HumanoidRootPart for " .. other.Name)
			return
		end
		if other.Parent ~= Players or other.Character ~= character or tracked[other] then
			return
		end

		local attachment = Instance.new("Attachment")
		attachment.Name = PROMPT_ATTACHMENT_NAME
		attachment.Parent = root

		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "__LocalPrompt_" .. PROMPT_KIND
		prompt.ActionText = "Gift"
		prompt.ObjectText = ""
		prompt.MaxActivationDistance = PROMPT_DISTANCE
		prompt.RequiresLineOfSight = false
		prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt:SetAttribute("Theme", "TreeGroundPickup")
		prompt.Parent = attachment

		local record = {
			prompt = prompt,
			attachment = attachment,
			connections = {},
		}
		tracked[other] = record
		record.unregister = LocalPrompts.RegisterExternalPrompt(prompt, function()
			return isAvailable(other)
		end)
		record.connections[#record.connections + 1] = RuntimeGuard.Connect(prompt.Triggered, "GiftController.Triggered", function()
			onPromptTriggered(other)
		end)
	end)
end

local function bindPlayer(other)
	if other == player or playerConnections[other] then
		return
	end
	local connections = {}
	playerConnections[other] = connections
	connections[#connections + 1] = RuntimeGuard.Connect(other.CharacterAdded, "GiftController.CharacterAdded", function(character)
		bindCharacter(other, character)
	end)
	connections[#connections + 1] = RuntimeGuard.Connect(other.CharacterRemoving, "GiftController.CharacterRemoving", function()
		cleanupCharacter(other)
	end)
	if other.Character then
		bindCharacter(other, other.Character)
	end
end

local function cleanupPlayer(other)
	cleanupCharacter(other)
	local connections = playerConnections[other]
	if not connections then
		return
	end
	playerConnections[other] = nil
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
end

function GiftController.start()
	RuntimeGuard.Connect(resultRemote.OnClientEvent, "GiftController.Result", function(payload)
		if type(payload) ~= "table" or payload.requestId ~= pendingRequestId then
			return
		end
		pendingRequestId = nil
		if payload.success ~= true and payload.code ~= "recipient-inventory-full" then
			NotificationUi.show({
				kind = NotificationConfig.Kinds.Error,
				text = FAILURE_MESSAGES[payload.code] or DEFAULT_FAILURE_MESSAGE,
			})
		end
	end)

	RuntimeGuard.Connect(Players.PlayerAdded, "GiftController.PlayerAdded", bindPlayer)
	RuntimeGuard.Connect(Players.PlayerRemoving, "GiftController.PlayerRemoving", cleanupPlayer)
	for _, other in ipairs(Players:GetPlayers()) do
		bindPlayer(other)
	end
end

return GiftController
