-- Studio-only command surface for manual game events (Tsunami, Earthquake,
-- Alien...). GameEventService intentionally has no client or admin remote, and
-- command-bar/MCP execution runs in a separate VM whose requires are stateless
-- module copies -- so, like PlotStressTest, the live server watches an
-- attribute on ServerScriptService.Server and any VM can drive it:
--
--   Server:SetAttribute("GameEventDevCommand", HttpService:JSONEncode({
--       action = "start", eventId = "Earthquake", startsAtOffset = -21,
--   }))
--
-- Actions: start (eventId, startsAtOffset?, durationSeconds?),
-- stop (instanceId), complete (instanceId), disable-tutorial (all players),
-- grant-currency (amount, userId? defaults to the first player),
-- grant-durian-tickets (amount, pity?, userId? defaults to the first player),
-- merchant-offers (startsAt?, userId?) which reports this hour's three offers
-- and how many of each request the player holds,
-- grant-food (foodId, amount, userId? defaults to the first player),
-- pinata-spawn (variant), pinata-clear, pinata-debug,
-- pinata-damage (pinataId, amount, userId? defaults to the first player) --
-- which bypasses the swing cooldown so the break/split/drop/collect path can
-- be driven without hundreds of real swings.
-- Each command's outcome is JSON-encoded into the GameEventDevResult
-- attribute for the caller to read back.
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Server = script.Parent.Parent
local CurrencyService = require(Server:WaitForChild("CurrencyService"))
local FoodInventoryService = require(Server:WaitForChild("FoodInventoryService"))
local GameEventService = require(Server:WaitForChild("GameEventService"))
local PinataService = require(Server:WaitForChild("PinataService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local ToolGrantService = require(Server:WaitForChild("ToolGrantService"))
local TravellingMerchantService = require(Server:WaitForChild("TravellingMerchantService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
local Inventory = require(Shared:WaitForChild("Inventory"))
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local TravellingMerchant = require(Shared:WaitForChild("TravellingMerchant"))

local GameEventDev = {}

local SERVER_FOLDER = ServerScriptService:WaitForChild("Server")
local COMMAND_ATTR = "GameEventDevCommand"
local RESULT_ATTR = "GameEventDevResult"

local watchConnection = nil

local function writeResult(payload)
	SERVER_FOLDER:SetAttribute(RESULT_ATTR, HttpService:JSONEncode(payload))
end

local function disableTutorialForAll()
	local completed = 0
	for _, player in ipairs(Players:GetPlayers()) do
		local profile = PlayerDataService.GetProfile(player)
		if profile and profile.Data then
			profile.Data.Onboarding = Onboarding.CompleteState()
			PlayerReplicaService.PublishOnboarding(player, profile)
			completed += 1
		end
	end
	return { ok = true, completed = completed }
end

local function runCommand(command)
	local action = command.action
	if action == "start" then
		local options = {}
		if type(command.startsAtOffset) == "number" then
			options.startsAt = Workspace:GetServerTimeNow() + command.startsAtOffset
		end
		if type(command.durationSeconds) == "number" then
			options.durationSeconds = command.durationSeconds
		end
		local ok, result = GameEventService.StartManualEvent(command.eventId, options)
		if ok then
			return { ok = true, instanceId = result.instanceId, startsAt = result.startsAt, endsAt = result.endsAt }
		end
		return { ok = false, code = tostring(result) }
	elseif action == "stop" then
		local ok, code = GameEventService.StopManualEvent(command.instanceId)
		return { ok = ok == true, code = code }
	elseif action == "complete" then
		GameEventService.CompleteInstance(command.instanceId)
		return { ok = true }
	elseif action == "disable-tutorial" then
		return disableTutorialForAll()
	elseif action == "grant-currency" then
		local amount = tonumber(command.amount)
		if not amount or amount <= 0 then
			return { ok = false, code = "invalid-amount" }
		end
		local player = nil
		if command.userId ~= nil then
			player = Players:GetPlayerByUserId(tonumber(command.userId) or 0)
		else
			player = Players:GetPlayers()[1]
		end
		local profile = player and PlayerDataService.GetProfile(player)
		if not profile then
			return { ok = false, code = "no-profile" }
		end
		CurrencyService.Add(player, profile, amount, false)
		return { ok = true, currency = profile.Data.Currency }
	elseif action == "grant-durian-tickets" then
		local amount = tonumber(command.amount)
		if not amount or amount <= 0 then
			return { ok = false, code = "invalid-amount" }
		end
		local player = nil
		if command.userId ~= nil then
			player = Players:GetPlayerByUserId(tonumber(command.userId) or 0)
		else
			player = Players:GetPlayers()[1]
		end
		local profile = player and PlayerDataService.GetProfile(player)
		if not profile then
			return { ok = false, code = "no-profile" }
		end
		profile.Data.DurianTickets = math.max(math.floor(tonumber(profile.Data.DurianTickets) or 0), 0) + math.floor(amount)
		if tonumber(command.pity) then
			profile.Data.DurianPackPity = math.max(math.floor(tonumber(command.pity)), 0)
		end
		PlayerReplicaService.PublishDurianPack(player, profile)
		return { ok = true, durianTickets = profile.Data.DurianTickets, durianPackPity = profile.Data.DurianPackPity }
	elseif action == "merchant-offers" then
		-- Dumps whichever three offers this hour rolled, plus what the player
		-- actually holds against each request, so a trade can be set up without
		-- guessing which of the two pool entries is live.
		local startsAt = tonumber(command.startsAt)
		if not startsAt then
			local record = TravellingMerchantService.ActiveRecord()
			startsAt = record and record.startsAt or Workspace:GetServerTimeNow()
		end
		local player = nil
		if command.userId ~= nil then
			player = Players:GetPlayerByUserId(tonumber(command.userId) or 0)
		else
			player = Players:GetPlayers()[1]
		end

		local offers = {}
		for slot, offer in ipairs(TravellingMerchant.OffersFor(startsAt)) do
			offers[slot] = {
				slot = slot,
				offerId = offer.offerId,
				requestFoodId = offer.request.foodId,
				requestAmount = offer.request.amount,
				held = player and FoodInventoryService.CountSpendable(player, offer.request.foodId) or nil,
				rewardKind = offer.reward.kind,
			}
		end
		return {
			ok = true,
			active = TravellingMerchantService.IsActive(),
			startsAt = startsAt,
			offers = offers,
		}
	elseif action == "grant-food" then
		-- Bulk food for merchant trades: high-count requests are not something
		-- to farm by hand every test run.
		local amount = math.floor(tonumber(command.amount) or 0)
		if amount <= 0 or amount > 250 then
			return { ok = false, code = "invalid-amount" }
		end
		local foodId = command.foodId
		if type(foodId) ~= "string" or not Food.GetTemplate(foodId) then
			return { ok = false, code = "unknown-food" }
		end
		local player = nil
		if command.userId ~= nil then
			player = Players:GetPlayerByUserId(tonumber(command.userId) or 0)
		else
			player = Players:GetPlayers()[1]
		end
		if not player then
			return { ok = false, code = "no-player" }
		end

		local tools = {}
		for _ = 1, amount do
			local tool = Food.MakeTool(foodId)
			if not tool then
				for _, made in ipairs(tools) do
					made:Destroy()
				end
				return { ok = false, code = "make-failed" }
			end
			tools[#tools + 1] = tool
		end
		local granted, code = ToolGrantService.GrantTools(player, tools, {
			autoEquip = false,
			maxItems = Inventory.HARD_MAX_ITEMS,
		})
		if not granted then
			return { ok = false, code = tostring(code) }
		end
		return { ok = true, granted = amount, foodId = foodId }
	elseif action == "pinata-spawn" then
		local ok, idOrCode = PinataService.Spawn(command.variant)
		return { ok = ok == true, result = idOrCode }
	elseif action == "pinata-clear" then
		return { ok = true, cleared = PinataService.ClearAll() }
	elseif action == "pinata-damage" then
		-- Bypasses the swing cooldown so the break/split/drop path is testable
		-- without hundreds of real swings. Studio-only inside PinataService.
		local player = nil
		if command.userId ~= nil then
			player = Players:GetPlayerByUserId(tonumber(command.userId) or 0)
		else
			player = Players:GetPlayers()[1]
		end
		local userId = tonumber(command.userId) or (player and player.UserId)
		local ok, result = PinataService.DebugDamage(command.pinataId, userId, command.amount)
		return { ok = ok == true, result = result }
	elseif action == "pinata-debug" then
		-- Includes the target player's profile figures so an MCP/command-bar VM
		-- (which holds its own stateless module copies and therefore sees no
		-- profiles) can still observe reward grants landing.
		local player = nil
		if command.userId ~= nil then
			player = Players:GetPlayerByUserId(tonumber(command.userId) or 0)
		else
			player = Players:GetPlayers()[1]
		end
		local profile = player and PlayerDataService.GetProfile(player)
		return {
			ok = true,
			debug = PinataService.Debug(),
			userId = player and player.UserId or nil,
			currency = profile and profile.Data.Currency or nil,
			durianTickets = profile and profile.Data.DurianTickets or nil,
		}
	end
	return { ok = false, code = "unknown-action" }
end

local function onCommand()
	local raw = SERVER_FOLDER:GetAttribute(COMMAND_ATTR)
	if type(raw) ~= "string" or raw == "" then
		return
	end
	SERVER_FOLDER:SetAttribute(COMMAND_ATTR, nil)
	local ok, command = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or type(command) ~= "table" then
		writeResult({ ok = false, code = "invalid-json" })
		return
	end
	writeResult(runCommand(command))
end

function GameEventDev.Watch()
	if not RunService:IsStudio() then
		return false, "not-studio"
	end
	if watchConnection then
		return true
	end
	watchConnection = RuntimeGuard.Connect(SERVER_FOLDER:GetAttributeChangedSignal(COMMAND_ATTR), "GameEventDev.CommandChanged", onCommand)
	onCommand()
	return true
end

return GameEventDev
