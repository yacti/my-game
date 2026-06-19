local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local Cosmetics = require(Shared:WaitForChild("Cosmetics"))
local Rarities = require(Shared:WaitForChild("Rarities"))
local State = require(Shared:WaitForChild("State"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))
local ToolGrantService = require(script.Parent:WaitForChild("ToolGrantService"))

local CosmeticTools = {}
local TOOL_VISUAL_SCALE = 0.5
local TOOL_HANDLE_SIZE = Vector3.new(0.2, 0.2, 0.2)
local TOOL_VISUAL_NAME = "CosmeticVisual"

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
	part.Massless = true
	if isHandle then
		part.Transparency = 1
		part.CastShadow = false
	end
end

local function clearTemplateBody(tool)
	for _, child in ipairs(tool:GetChildren()) do
		if child:IsA("BasePart") or child.Name == TOOL_VISUAL_NAME then
			child:Destroy()
		end
	end
end

local function makeToolHandle(tool)
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = TOOL_HANDLE_SIZE
	handle.CFrame = CFrame.identity
	configureBodyPart(handle, true)
	handle.Parent = tool
	return handle
end

local function weldToHandle(handle, part)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = part
	weld.Parent = part
end

local function insertCosmeticVisual(tool, template)
	clearTemplateBody(tool)
	local handle = makeToolHandle(tool)

	if template:IsA("BasePart") then
		local visual = template:Clone()
		visual.Name = TOOL_VISUAL_NAME
		visual.Size *= TOOL_VISUAL_SCALE
		visual.CFrame = CFrame.identity
		configureBodyPart(visual, false)
		visual.Parent = tool
		weldToHandle(handle, visual)
		return true
	end

	if template:IsA("Model") then
		if not template.PrimaryPart then
			warn(string.format("[CosmeticTools] Cosmetic model %s missing PrimaryPart", template:GetFullName()))
			return false
		end

		local clone = template:Clone()
		clone.Name = TOOL_VISUAL_NAME
		clone:ScaleTo(clone:GetScale() * TOOL_VISUAL_SCALE)
		local sourcePrimary = clone.PrimaryPart
		clone:PivotTo(sourcePrimary.CFrame:Inverse() * clone:GetPivot())
		clone.Parent = tool

		for _, descendant in ipairs(clone:GetDescendants()) do
			if descendant:IsA("BasePart") then
				configureBodyPart(descendant, false)
				if descendant == sourcePrimary and descendant.Transparency >= 1 then
					descendant:Destroy()
				else
					weldToHandle(handle, descendant)
				end
			end
		end
		return true
	end

	return false
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
	tool.RequiresHandle = true
	tool:SetAttribute(State.Cosmetic.Id, cosmeticId)
	applyToolRarity(tool, template:GetAttribute(State.Cosmetic.Rarity))
	ToolIdentity.AssignGuid(tool)

	if not insertCosmeticVisual(tool, template) then
		tool:Destroy()
		return nil
	end

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
