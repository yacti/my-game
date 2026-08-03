local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PetSkinCatalog = require(Shared:WaitForChild("PetSkinCatalog"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local PetSkinToolAnimationController = {}

local records = setmetatable({}, { __mode = "k" })

local function cleanup(tool)
	local record = records[tool]
	if not record then return end
	if record.connection then record.connection:Disconnect() end
	if record.track then
		pcall(function()
			record.track:Stop(0.1)
			record.track:Destroy()
		end)
	end
	if record.animation then record.animation:Destroy() end
	records[tool] = nil
end

local function bindTool(tool)
	if records[tool] or not tool:IsA("Tool") then return end
	local petSkinId = tool:GetAttribute(State.PetSkin.Id)
	local definition = type(petSkinId) == "string" and PetSkinCatalog.Get(petSkinId) or nil
	if not definition then return end
	local animator = tool:FindFirstChildWhichIsA("Animator", true)
	if not animator then return end

	local animation = Instance.new("Animation")
	animation.Name = "HeldPetSkinIdleAnimation"
	animation.AnimationId = definition.IdleAnimationId
	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		animation:Destroy()
		warn("[PetSkinToolAnimationController] Failed to load " .. definition.IdleAnimationId .. ": " .. tostring(track))
		return
	end
	track.Looped = true
	track:Play(0.1)
	local record = { animation = animation, track = track }
	records[tool] = record
	record.connection = RuntimeGuard.Connect(tool.AncestryChanged, "PetSkinToolAnimationController.ToolAncestry", function()
		local parent = tool.Parent
		if not (parent and parent:IsA("Model") and parent:FindFirstChildOfClass("Humanoid")) then
			cleanup(tool)
		end
	end)
end

local function bindCharacter(character)
	for _, child in ipairs(character:GetChildren()) do
		bindTool(child)
	end
	RuntimeGuard.Connect(character.ChildAdded, "PetSkinToolAnimationController.CharacterChildAdded", bindTool)
	RuntimeGuard.Connect(character.ChildRemoved, "PetSkinToolAnimationController.CharacterChildRemoved", function(child)
		cleanup(child)
	end)
end

local function bindPlayer(player)
	if player.Character then bindCharacter(player.Character) end
	RuntimeGuard.Connect(player.CharacterAdded, "PetSkinToolAnimationController.CharacterAdded", bindCharacter)
end

function PetSkinToolAnimationController.start()
	for _, player in ipairs(Players:GetPlayers()) do bindPlayer(player) end
	RuntimeGuard.Connect(Players.PlayerAdded, "PetSkinToolAnimationController.PlayerAdded", bindPlayer)
end

return PetSkinToolAnimationController
