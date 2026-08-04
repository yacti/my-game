local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
local Inventory = require(Shared:WaitForChild("Inventory"))
local Mutations = require(Shared:WaitForChild("Mutations"))
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
	local mutationIds = Mutations.SanitizeList(record.mutationIds or record.mutations or record[State.Food.MutationIds])
	if #mutationIds > 0 then
		clean.mutationIds = mutationIds
	end
	local primaryMutationId = Mutations.Primary(mutationIds, record.primaryMutationId or record.primaryMutation or record[State.Food.PrimaryMutationId])
	if primaryMutationId then
		clean.primaryMutationId = primaryMutationId
	end
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
	if record.favourite == true then
		clean.favourite = true
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
	local mutationIds = Food.MutationIdsOf(tool)
	if #mutationIds > 0 then
		record.mutationIds = mutationIds
	end
	local primaryMutationId = Mutations.Primary(mutationIds, Food.PrimaryMutationIdOf(tool))
	if primaryMutationId then
		record.primaryMutationId = primaryMutationId
	end
	local scale = toolScale(tool)
	if scale then
		record.scale = scale
	end
	if ToolIdentity.IsFavourite(tool) then
		record.favourite = true
	end
	return record
end

function FoodInventoryService.SerializeTools(player)
	local records = {}
	Inventory.ForEachTool(player, function(item)
		local record = FoodInventoryService.SerializeTool(item)
		if record then
			records[#records + 1] = record
		end
	end)
	return FoodInventoryService.SanitizeRecords(records)
end

function FoodInventoryService.CountTools(player)
	return FoodInventoryService.CountRecords(FoodInventoryService.SerializeTools(player))
end

-- Every held tool of one FoodId that is legal to spend, worst first.
--
-- Favourites are excluded outright: favouriting is the player saying "not this
-- one", and it is the same protection InventoryDeleteService honours.
--
-- Order matters as much as the filter. Fruit of the same FoodId varies wildly in
-- XP once mutations and growth events are involved, so spending an arbitrary
-- ten Plums can quietly eat the mutated ones a player was saving. Sorting
-- ascending by XP means a trade always takes the least valuable copies first.
local function spendableTools(player, foodId)
	local matches = {}
	Inventory.ForEachTool(player, function(tool)
		if not Inventory.IsCountableTool(tool) then
			return
		end
		if not Food.IsFood(tool) or Food.IdOf(tool) ~= foodId then
			return
		end
		if ToolIdentity.IsFavourite(tool) then
			return
		end
		matches[#matches + 1] = {
			tool = tool,
			xp = nonnegativeNumber(Food.XPOf(tool), 0),
			-- Stable tiebreak so equal-XP tools consume in a deterministic order
			-- rather than depending on table.sort's behaviour on ties.
			order = #matches + 1,
		}
	end)
	table.sort(matches, function(left, right)
		if left.xp ~= right.xp then
			return left.xp < right.xp
		end
		return left.order < right.order
	end)
	return matches
end

-- How many tools of this FoodId the player could actually spend right now.
-- Deliberately not Food.CountByType: that counts favourites too, so gating a
-- trade on it would offer a trade the consume step then refuses.
function FoodInventoryService.CountSpendable(player, foodId)
	if type(foodId) ~= "string" or foodId == "" then
		return 0
	end
	return #spendableTools(player, foodId)
end

-- Consumes exactly `amount` tools of `foodId`, cheapest first.
--
-- All-or-nothing, and that is the whole point of collecting before destroying:
-- destroying as we scan would leave a player who is three short having already
-- lost the ones we did find. Returns ok, code, consumedCount.
function FoodInventoryService.ConsumeFoodId(player, foodId, amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then
		return false, "invalid-amount", 0
	end
	if type(foodId) ~= "string" or foodId == "" then
		return false, "invalid-food", 0
	end

	local matches = spendableTools(player, foodId)
	if #matches < amount then
		return false, "not-enough", #matches
	end

	-- Re-check each tool at the moment of destruction. The scan above does not
	-- yield, but a tool can still have been consumed by a concurrent path
	-- between calls, and DestroyIfGuidMatches is the same atomic take the
	-- deposit flows use.
	local consumed = 0
	for index = 1, amount do
		local tool = matches[index].tool
		local guid = ToolIdentity.EnsureGuid(tool)
		if ToolIdentity.DestroyIfGuidMatches(tool, guid) then
			consumed += 1
		end
	end

	if consumed < amount then
		-- Nothing above yields, so reaching here means something took the tools
		-- out from under us. There is no rollback -- the destroyed ones are
		-- gone -- so the only choice that does not rob the player is to treat
		-- the trade as paid and let the reward land. Loud, because it means an
		-- assumption about tool ownership broke.
		warn(string.format(
			"[FoodInventoryService] Partial consume for %s: took %d of %d %s",
			tostring(player), consumed, amount, foodId
		))
	end
	return true, "ok", consumed
end

function FoodInventoryService.MakeTool(record)
	local clean = FoodInventoryService.SanitizeRecord(record)
	if not clean then
		return nil
	end
	local tool = Food.MakeTool(clean.foodId, clean.xp, clean.mutationIds, clean.primaryMutationId)
	if not tool then
		return nil
	end
	if ToolIdentity.IsValidGuid(clean.guid) then
		tool:SetAttribute(State.Tool.Guid, clean.guid)
	else
		ToolIdentity.EnsureGuid(tool)
	end
	ToolIdentity.SetFavourite(tool, clean.favourite == true)
	applyToolScale(tool, clean.scale)
	return tool
end

return FoodInventoryService
