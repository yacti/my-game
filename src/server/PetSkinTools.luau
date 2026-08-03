local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local Inventory = require(Shared:WaitForChild("Inventory"))
local PetSkinCatalog = require(Shared:WaitForChild("PetSkinCatalog"))
local State = require(Shared:WaitForChild("State"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))
local ToolGrantService = require(script.Parent:WaitForChild("ToolGrantService"))

local PetSkinTools = {}

local HANDLE_SIZE = Vector3.new(0.2, 0.2, 0.2)
local VISUAL_NAME = "PetSkinVisual"

local function amountOrZero(amount)
	amount = tonumber(amount) or 0
	if amount ~= amount or math.abs(amount) == math.huge then
		return 0
	end
	return math.max(math.floor(amount), 0)
end

local function destroyPrepared(prepared)
	for _, tool in ipairs(type(prepared) == "table" and prepared.tools or {}) do
		if tool then
			tool:Destroy()
		end
	end
end

local function configurePart(part, isHandle)
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

local function maxBoundsDimension(model)
	local _, size = model:GetBoundingBox()
	return math.max(size.X, size.Y, size.Z)
end

local function makeHandle(tool)
	for _, child in ipairs(tool:GetChildren()) do
		if child:IsA("BasePart") or child.Name == VISUAL_NAME then
			child:Destroy()
		end
	end
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = HANDLE_SIZE
	handle.CFrame = CFrame.identity
	configurePart(handle, true)
	handle.Parent = tool
	return handle
end

local function insertVisual(tool, template, definition)
	local handle = makeHandle(tool)
	local visual = template:Clone()
	visual.Name = VISUAL_NAME
	local currentMax = maxBoundsDimension(visual)
	if currentMax <= 0 then
		visual:Destroy()
		return false
	end
	visual:ScaleTo(visual:GetScale() * definition.ToolMaxDimension / currentMax)
	visual:PivotTo(CFrame.Angles(0, math.rad(definition.ToolYawDegrees or 0), 0))
	local boundsCF = visual:GetBoundingBox()
	visual:PivotTo(visual:GetPivot() + -boundsCF.Position)
	visual.Parent = tool

	local hasPart = false
	for _, descendant in ipairs(visual:GetDescendants()) do
		if descendant:IsA("BasePart") then
			hasPart = true
			configurePart(descendant, false)
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = handle
			weld.Part1 = descendant
			weld.Parent = descendant
		elseif descendant:IsA("ProximityPrompt") or descendant:IsA("ClickDetector") then
			descendant:Destroy()
		end
	end
	if not hasPart then
		visual:Destroy()
		return false
	end
	return true
end

function PetSkinTools.MakePetSkinTool(petSkinId)
	local definition = PetSkinCatalog.Get(petSkinId)
	local template = PetSkinCatalog.TemplateFor(petSkinId)
	if not (definition and template) then
		warn("[PetSkinTools] No pet skin template for tool: " .. tostring(petSkinId))
		return nil
	end
	local wrapper = Assets.WaitFor(Assets.Names.PetSkinTool)
	if not (wrapper and wrapper:IsA("Tool")) then
		warn("[PetSkinTools] ReplicatedStorage.Assets.PetSkinTool must be a Tool")
		return nil
	end

	local tool = wrapper:Clone()
	tool.Name = template.Name
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool:SetAttribute(State.PetSkin.Id, petSkinId)
	tool:SetAttribute(State.Tool.Rarity, definition.Rarity)
	ToolIdentity.AssignGuid(tool)
	if not insertVisual(tool, template, definition) then
		tool:Destroy()
		return nil
	end
	return tool
end

function PetSkinTools.IsPetSkinTool(item)
	if not (item and item:IsA("Tool")) then
		return false
	end
	local petSkinId = item:GetAttribute(State.PetSkin.Id)
	return type(petSkinId) == "string"
		and PetSkinCatalog.Get(petSkinId) ~= nil
		and PetSkinCatalog.TemplateFor(petSkinId) ~= nil
end

function PetSkinTools.PetSkinIdOf(item)
	return PetSkinTools.IsPetSkinTool(item) and item:GetAttribute(State.PetSkin.Id) or nil
end

function PetSkinTools.CountByPetSkin(player)
	local counts = {}
	Inventory.ForEachTool(player, function(item)
		local petSkinId = PetSkinTools.PetSkinIdOf(item)
		if petSkinId then
			counts[petSkinId] = (counts[petSkinId] or 0) + 1
		end
	end)
	return counts
end

function PetSkinTools.PrepareGrant(petSkinId, amount)
	amount = amountOrZero(amount)
	if type(petSkinId) ~= "string" or not PetSkinCatalog.Get(petSkinId) then
		return nil, "invalid-pet-skin"
	end
	if amount <= 0 then
		return nil, "invalid-amount"
	end
	local prepared = { petSkinId = petSkinId, amount = amount, tools = {} }
	for _ = 1, amount do
		local tool = PetSkinTools.MakePetSkinTool(petSkinId)
		if not tool then
			destroyPrepared(prepared)
			return nil, "no-template"
		end
		prepared.tools[#prepared.tools + 1] = tool
	end
	return prepared, "ok"
end

function PetSkinTools.ApplyPrepared(player, profile, prepared, grantOptions)
	if not (player and profile and type(prepared) == "table") then
		destroyPrepared(prepared)
		return false, "invalid-grant"
	end
	local petSkinId = prepared.petSkinId
	local amount = amountOrZero(prepared.amount)
	if not PetSkinCatalog.Get(petSkinId) or amount <= 0 then
		destroyPrepared(prepared)
		return false, "invalid-grant"
	end
	local granted, code = ToolGrantService.GrantTools(player, prepared.tools, grantOptions)
	if not granted then
		destroyPrepared(prepared)
		return false, code
	end
	profile.Data.PetSkinInventory = profile.Data.PetSkinInventory or {}
	profile.Data.PetSkinInventory[petSkinId] = (profile.Data.PetSkinInventory[petSkinId] or 0) + amount
	return true, "ok"
end

function PetSkinTools.DestroyPrepared(prepared)
	destroyPrepared(prepared)
end

return PetSkinTools
