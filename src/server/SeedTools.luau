local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.Shared:WaitForChild("Assets"))
local Rarities = require(ReplicatedStorage.Shared:WaitForChild("Rarities"))
local Seeds = require(ReplicatedStorage.Shared:WaitForChild("Seeds"))
local State = require(ReplicatedStorage.Shared:WaitForChild("State"))
local ToolIdentity = require(ReplicatedStorage.Shared:WaitForChild("ToolIdentity"))
local ToolGrantService = require(script.Parent:WaitForChild("ToolGrantService"))

local SeedTools = {}

local function applyToolRarity(tool, rarity)
	if type(rarity) == "string" and Rarities.IsValid(rarity) then
		tool:SetAttribute(State.Tool.Rarity, rarity)
	end
end

local function amountOrZero(amount)
	amount = tonumber(amount) or 0
	if type(amount) ~= "number" or amount ~= amount or math.abs(amount) == math.huge then
		return 0
	end
	return math.max(math.floor(amount), 0)
end

local function destroyPrepared(prepared)
	if type(prepared) ~= "table" then
		return
	end
	for _, tool in ipairs(prepared.tools or {}) do
		if tool then
			tool:Destroy()
		end
	end
end

local function configureBodyPart(part, isHandle)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = not isHandle
end

local function clearTemplateHandle(tool)
	local handle = tool:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		handle:Destroy()
	end
end

local function insertSeedVisual(tool, seedTemplate)
	clearTemplateHandle(tool)

	if seedTemplate:IsA("BasePart") then
		local handle = seedTemplate:Clone()
		handle.Name = "Handle"
		configureBodyPart(handle, true)
		handle.Parent = tool
		return true
	end

	if seedTemplate:IsA("Model") then
		if not seedTemplate.PrimaryPart then
			warn(string.format("[SeedTools] Seed model %s missing PrimaryPart", seedTemplate:GetFullName()))
			return false
		end

		local clone = seedTemplate:Clone()
		local handle = clone.PrimaryPart
		handle.Name = "Handle"
		configureBodyPart(handle, true)
		handle.Parent = tool

		for _, descendant in ipairs(clone:GetDescendants()) do
			if descendant:IsA("BasePart") and descendant ~= handle then
				configureBodyPart(descendant, false)
				descendant.Parent = tool
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = handle
				weld.Part1 = descendant
				weld.Parent = descendant
			end
		end
		clone:Destroy()
		return true
	end

	return false
end

function SeedTools.MakeSeedTool(seedId)
	local seedTemplate = Seeds.GetTemplate(seedId)
	if not seedTemplate then
		warn("[SeedTools] No seed template for tool: " .. tostring(seedId))
		return nil
	end

	local wrapper = Assets.WaitFor(Assets.Names.SeedTool)
	if not wrapper:IsA("Tool") then
		warn("[SeedTools] ReplicatedStorage.Assets.SeedTool must be a Tool")
		return nil
	end

	local tool = wrapper:Clone()
	tool.Name = seedTemplate.Name
	tool.RequiresHandle = true
	tool:SetAttribute(State.Seed.Id, seedId)
	applyToolRarity(tool, seedTemplate:GetAttribute(Seeds.Attributes.Rarity))
	ToolIdentity.AssignGuid(tool)

	if not insertSeedVisual(tool, seedTemplate) then
		tool:Destroy()
		return nil
	end

	return tool
end

function SeedTools.IsSeedTool(item)
	if not (item and item:IsA("Tool")) then
		return false
	end
	local seedId = item:GetAttribute(State.Seed.Id)
	return type(seedId) == "string" and seedId ~= "" and Seeds.GetTemplate(seedId) ~= nil
end

function SeedTools.SeedIdOf(item)
	if not SeedTools.IsSeedTool(item) then
		return nil
	end
	return item:GetAttribute(State.Seed.Id)
end

function SeedTools.CountBySeed(player)
	local counts = {}
	local function add(item)
		local seedId = SeedTools.SeedIdOf(item)
		if seedId then
			counts[seedId] = (counts[seedId] or 0) + 1
		end
	end
	for _, item in ipairs(player.Backpack:GetChildren()) do
		add(item)
	end
	if player.Character then
		add(player.Character:FindFirstChildWhichIsA("Tool"))
	end
	return counts
end

function SeedTools.PrepareGrant(seedId, amount)
	amount = amountOrZero(amount)
	if type(seedId) ~= "string" or seedId == "" then
		return nil, "invalid-seed"
	end
	if amount <= 0 then
		return nil, "invalid-amount"
	end

	local tools = {}
	for _ = 1, amount do
		local tool = SeedTools.MakeSeedTool(seedId)
		if not tool then
			destroyPrepared({ tools = tools })
			return nil, "no-template"
		end
		tools[#tools + 1] = tool
	end

	return {
		seedId = seedId,
		amount = amount,
		tools = tools,
	}
end

function SeedTools.ApplyPrepared(player, profile, prepared)
	if not (player and profile and type(prepared) == "table") then
		return false, "invalid-grant"
	end
	local seedId = prepared.seedId
	local amount = amountOrZero(prepared.amount)
	if type(seedId) ~= "string" or seedId == "" or amount <= 0 then
		destroyPrepared(prepared)
		return false, "invalid-grant"
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		destroyPrepared(prepared)
		return false, "no-backpack"
	end

	profile.Data.SeedInventory = profile.Data.SeedInventory or {}
	profile.Data.SeedInventory[seedId] = (profile.Data.SeedInventory[seedId] or 0) + amount

	return ToolGrantService.GrantTools(player, prepared.tools)
end

function SeedTools.DestroyPrepared(prepared)
	destroyPrepared(prepared)
end

return SeedTools
