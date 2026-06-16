local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local Cosmetics = require(Shared:WaitForChild("Cosmetics"))
local Rarities = require(Shared:WaitForChild("Rarities"))
local State = require(Shared:WaitForChild("State"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))
local ToolGrantService = require(script.Parent:WaitForChild("ToolGrantService"))

local CosmeticTools = {}

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

local function configureHeldToolQuery(tool)
	for _, descendant in ipairs(tool:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanQuery = false
		end
	end
end

function CosmeticTools.MakeCosmeticTool(cosmeticId)
	local template = Cosmetics.GetTemplate(cosmeticId)
	if not template then
		warn("[CosmeticTools] No cosmetic template for tool: " .. tostring(cosmeticId))
		return nil
	end

	local wrapper = Assets.WaitFor(Assets.Names.CosmeticTool)
	if not wrapper:IsA("Tool") then
		warn("[CosmeticTools] ReplicatedStorage.Assets.CosmeticTool must be a Tool")
		return nil
	end

	local tool = wrapper:Clone()
	tool.Name = template.Name
	configureHeldToolQuery(tool)
	tool:SetAttribute(State.Cosmetic.Id, cosmeticId)
	applyToolRarity(tool, template:GetAttribute(State.Cosmetic.Rarity))
	ToolIdentity.AssignGuid(tool)
	return tool
end

function CosmeticTools.IsCosmeticTool(item)
	if not (item and item:IsA("Tool")) then
		return false
	end
	local cosmeticId = item:GetAttribute(State.Cosmetic.Id)
	return type(cosmeticId) == "string" and cosmeticId ~= "" and Cosmetics.GetTemplate(cosmeticId) ~= nil
end

function CosmeticTools.CosmeticIdOf(item)
	if not CosmeticTools.IsCosmeticTool(item) then
		return nil
	end
	return item:GetAttribute(State.Cosmetic.Id)
end

function CosmeticTools.CountByCosmetic(player)
	local counts = {}
	local function add(item)
		local cosmeticId = CosmeticTools.CosmeticIdOf(item)
		if cosmeticId then
			counts[cosmeticId] = (counts[cosmeticId] or 0) + 1
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

function CosmeticTools.PrepareGrant(cosmeticId, amount)
	amount = amountOrZero(amount)
	if type(cosmeticId) ~= "string" or cosmeticId == "" then
		return nil, "invalid-cosmetic"
	end
	if amount <= 0 then
		return nil, "invalid-amount"
	end

	local tools = {}
	for _ = 1, amount do
		local tool = CosmeticTools.MakeCosmeticTool(cosmeticId)
		if not tool then
			destroyPrepared({ tools = tools })
			return nil, "no-template"
		end
		tools[#tools + 1] = tool
	end

	return {
		cosmeticId = cosmeticId,
		amount = amount,
		tools = tools,
	}
end

function CosmeticTools.ApplyPrepared(player, profile, prepared)
	if not (player and profile and type(prepared) == "table") then
		return false, "invalid-grant"
	end
	local cosmeticId = prepared.cosmeticId
	local amount = amountOrZero(prepared.amount)
	if type(cosmeticId) ~= "string" or cosmeticId == "" or amount <= 0 then
		destroyPrepared(prepared)
		return false, "invalid-grant"
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		destroyPrepared(prepared)
		return false, "no-backpack"
	end

	local granted, code = ToolGrantService.GrantTools(player, prepared.tools)
	if not granted then
		destroyPrepared(prepared)
		return false, code
	end

	profile.Data.CosmeticInventory = profile.Data.CosmeticInventory or {}
	profile.Data.CosmeticInventory[cosmeticId] = (profile.Data.CosmeticInventory[cosmeticId] or 0) + amount
	return true
end

function CosmeticTools.DestroyPrepared(prepared)
	destroyPrepared(prepared)
end

return CosmeticTools
