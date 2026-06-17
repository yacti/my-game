local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NotificationService = require(script.Parent:WaitForChild("NotificationService"))

local Inventory = require(ReplicatedStorage.Shared:WaitForChild("Inventory"))
local RuntimeGuard = require(ReplicatedStorage.Shared:WaitForChild("RuntimeGuard"))

local ToolGrantService = {}

local DEFERRED_AUTO_EQUIP_DELAY = 0.05
local DEFAULT_AUTO_EQUIP_BURST_GAP = 3
local AUTO_EQUIP_POLICY_FIRST_IN_BURST = "firstInBurst"
local INVENTORY_CAP_NOTIFY_COOLDOWN = 2
local autoEquipLastRequestByUserId = {}
local inventoryCapNotifiedAtByUserId = {}

local function shouldAutoEquip(options)
	return type(options) ~= "table" or options.autoEquip ~= false
end

local function shouldDeferAutoEquip(options)
	return type(options) == "table" and options.deferAutoEquip == true
end

local function autoEquipPolicy(options)
	if type(options) ~= "table" then
		return nil
	end
	return options.autoEquipPolicy
end

local function autoEquipBurstGap(options)
	if type(options) ~= "table" then
		return DEFAULT_AUTO_EQUIP_BURST_GAP
	end
	local gap = tonumber(options.autoEquipBurstGap)
	if type(gap) ~= "number" or gap <= 0 then
		return DEFAULT_AUTO_EQUIP_BURST_GAP
	end
	return gap
end

local function userKey(player)
	return player and player.UserId or nil
end

local function shouldRunAutoEquip(player, options)
	if autoEquipPolicy(options) ~= AUTO_EQUIP_POLICY_FIRST_IN_BURST then
		return true
	end

	local key = userKey(player)
	if key == nil then
		return false
	end

	local now = os.clock()
	local lastRequestAt = autoEquipLastRequestByUserId[key]
	local gap = autoEquipBurstGap(options)
	local startsNewBurst = lastRequestAt == nil or now - lastRequestAt >= gap
	autoEquipLastRequestByUserId[key] = now
	if not startsNewBurst then
		return false
	end
	return true
end

local function equippedHumanoid(player)
	local character = player and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid
end

local function autoEquip(player, tool, options)
	local shouldEquip = shouldRunAutoEquip(player, options)
	if not shouldEquip then
		return
	end

	if shouldDeferAutoEquip(options) then
		task.delay(DEFERRED_AUTO_EQUIP_DELAY, function()
			if player and player.Parent and tool and tool.Parent then
				ToolGrantService.EquipLatest(player, tool)
			end
		end)
		return
	end

	ToolGrantService.EquipLatest(player, tool)
end

function ToolGrantService.EquipLatest(player, tool)
	if not (tool and tool:IsA("Tool")) then
		return false
	end
	local humanoid = equippedHumanoid(player)
	if not humanoid then
		return false
	end

	local ok = RuntimeGuard.Run("ToolGrantService.EquipLatest", function()
		humanoid:EquipTool(tool)
	end)
	return ok == true
end

-- Rate-limited so cap-blocked pickup spam (trees allow 5 clicks/s) does not
-- flood the notification feed.
local function notifyInventoryCapReached(player)
	local key = userKey(player)
	if key == nil then
		return
	end
	local now = os.clock()
	local notifiedAt = inventoryCapNotifiedAtByUserId[key]
	if notifiedAt and now - notifiedAt < INVENTORY_CAP_NOTIFY_COOLDOWN then
		return
	end
	inventoryCapNotifiedAtByUserId[key] = now
	NotificationService.Error(player, string.format("Inventory full (%d max). Delete or use some items first", Inventory.MAX_ITEMS))
end

local function countGrantTools(tools)
	local count = 0
	for _, tool in ipairs(tools) do
		if Inventory.IsCountableTool(tool) then
			count += 1
		end
	end
	return count
end

function ToolGrantService.GrantTool(player, tool, options)
	if not (tool and tool:IsA("Tool")) then
		return false, "invalid-tool"
	end
	local backpack = player and player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return false, "no-backpack"
	end
	if Inventory.IsCountableTool(tool) and Inventory.RemainingSlots(player) <= 0 then
		notifyInventoryCapReached(player)
		return false, "inventory-full"
	end

	tool.Parent = backpack
	if shouldAutoEquip(options) then
		autoEquip(player, tool, options)
	end
	return true
end

function ToolGrantService.GrantTools(player, tools, options)
	if type(tools) ~= "table" then
		return false, "invalid-tools"
	end
	local backpack = player and player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return false, "no-backpack"
	end
	local count = countGrantTools(tools)
	if count > Inventory.RemainingSlots(player) then
		notifyInventoryCapReached(player)
		return false, "inventory-full"
	end

	local latest = nil
	for _, tool in ipairs(tools) do
		if tool and tool:IsA("Tool") then
			tool.Parent = backpack
			latest = tool
		end
	end

	if latest and shouldAutoEquip(options) then
		autoEquip(player, latest, options)
	end
	return true
end

RuntimeGuard.Connect(Players.PlayerRemoving, "ToolGrantService.PlayerRemoving", function(player)
	local key = userKey(player)
	if key ~= nil then
		autoEquipLastRequestByUserId[key] = nil
		inventoryCapNotifiedAtByUserId[key] = nil
	end
end)

return ToolGrantService
