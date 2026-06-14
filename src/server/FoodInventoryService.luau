local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
local State = require(Shared:WaitForChild("State"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local FoodInventoryService = {}

local function finiteNumber(value, fallback)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return fallback or 0
	end
	return value
end

local function nonnegativeNumber(value, fallback)
	return math.max(finiteNumber(value, fallback), 0)
end

local function isRestorableFoodId(foodId)
	if type(foodId) ~= "string" or foodId == "" then
		return false
	end
	if Food.GetTemplate(foodId) then
		return true
	end
	return Food.IsJamFoodId(foodId)
end

local function equippedTool(player)
	local character = player and player.Character
	return character and character:FindFirstChildWhichIsA("Tool") or nil
end

local function toolScale(tool)
	if not (tool and tool:IsA("Tool")) then
		return nil
	end
	local ok, scale = pcall(function()
		return tool:GetScale()
	end)
	if ok and type(scale) == "number" and scale > 0 and scale == scale and math.abs(scale) < math.huge then
		return scale
	end
	return nil
end

local function applyToolScale(tool, scale)
	scale = tonumber(scale)
	if not (tool and scale and scale > 0 and scale == scale and math.abs(scale) < math.huge) then
		return
	end
	pcall(function()
		tool:ScaleTo(scale)
	end)
end

function FoodInventoryService.SanitizeRecord(record, seenGuids)
	if type(record) ~= "table" then
		return nil
	end
	local foodId = record.foodId or record.foodType
	if not isRestorableFoodId(foodId) then
		return nil
	end
	local xp = nonnegativeNumber(record.xp, Food.BaseXP(foodId))
	local clean = {
		foodId = foodId,
		xp = xp,
	}
	local guid = record.guid
	if ToolIdentity.IsValidGuid(guid) and (not seenGuids or not seenGuids[guid]) then
		clean.guid = guid
		if seenGuids then
			seenGuids[guid] = true
		end
	end
	local scale = tonumber(record.scale)
	if type(scale) == "number" and scale > 0 and scale == scale and math.abs(scale) < math.huge then
		clean.scale = scale
	end
	return clean
end

function FoodInventoryService.SanitizeRecords(records)
	local clean = {}
	local seenGuids = {}
	if type(records) ~= "table" then
		return clean
	end
	for _, record in ipairs(records) do
		local sanitized = FoodInventoryService.SanitizeRecord(record, seenGuids)
		if sanitized then
			clean[#clean + 1] = sanitized
		end
	end
	return clean
end

function FoodInventoryService.RecordsFromCountMap(countMap)
	local records = {}
	if type(countMap) ~= "table" then
		return records
	end
	local keys = {}
	for foodId in pairs(countMap) do
		keys[#keys + 1] = foodId
	end
	table.sort(keys, function(left, right)
		return tostring(left) < tostring(right)
	end)
	for _, foodId in ipairs(keys) do
		if isRestorableFoodId(foodId) then
			local count = math.max(math.floor(tonumber(countMap[foodId]) or 0), 0)
			local xp = Food.BaseXP(foodId)
			for _ = 1, count do
				records[#records + 1] = {
					foodId = foodId,
					xp = xp,
				}
			end
		end
	end
	return records
end

function FoodInventoryService.CountRecords(records)
	local counts = {}
	for _, record in ipairs(FoodInventoryService.SanitizeRecords(records)) do
		counts[record.foodId] = (counts[record.foodId] or 0) + 1
	end
	return counts
end

function FoodInventoryService.SerializeTool(tool)
	if not Food.IsFood(tool) then
		return nil
	end
	local foodId = Food.IdOf(tool)
	if not isRestorableFoodId(foodId) then
		return nil
	end
	local xp = Food.XPOf(tool)
	if xp == nil then
		return nil
	end
	local record = {
		foodId = foodId,
		xp = nonnegativeNumber(xp, Food.BaseXP(foodId)),
		guid = ToolIdentity.EnsureGuid(tool),
	}
	local scale = toolScale(tool)
	if scale then
		record.scale = scale
	end
	return record
end

function FoodInventoryService.SerializeTools(player)
	local records = {}
	local backpack = player and player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, item in ipairs(backpack:GetChildren()) do
			local record = FoodInventoryService.SerializeTool(item)
			if record then
				records[#records + 1] = record
			end
		end
	end
	local equipped = equippedTool(player)
	local record = FoodInventoryService.SerializeTool(equipped)
	if record then
		records[#records + 1] = record
	end
	return FoodInventoryService.SanitizeRecords(records)
end

function FoodInventoryService.CountTools(player)
	return FoodInventoryService.CountRecords(FoodInventoryService.SerializeTools(player))
end

function FoodInventoryService.MakeTool(record)
	local clean = FoodInventoryService.SanitizeRecord(record)
	if not clean then
		return nil
	end
	local tool = Food.MakeTool(clean.foodId, clean.xp)
	if not tool then
		return nil
	end
	if ToolIdentity.IsValidGuid(clean.guid) then
		tool:SetAttribute(State.Tool.Guid, clean.guid)
	else
		ToolIdentity.EnsureGuid(tool)
	end
	applyToolScale(tool, clean.scale)
	return tool
end

return FoodInventoryService
