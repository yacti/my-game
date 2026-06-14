local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))

local CurrencySpendSounds = {}

local REBIRTH_SUPPRESSION_DELAY_SECONDS = 0.15
local REBIRTH_SUPPRESSION_WINDOW_SECONDS = 2

local started = false
local latestRebirths = 0
local lastRebirthIncreaseClock = -math.huge

local function numberValue(value)
	return tonumber(value) or 0
end

local function shouldSuppressForRebirth(rebirthsAtDrop)
	return numberValue(PlayerStateStore.Get(PlayerStateStore.Fields.Rebirths)) > rebirthsAtDrop
		or os.clock() - lastRebirthIncreaseClock <= REBIRTH_SUPPRESSION_WINDOW_SECONDS
end

function CurrencySpendSounds.start()
	if started then
		return
	end
	started = true

	latestRebirths = numberValue(PlayerStateStore.Get(PlayerStateStore.Fields.Rebirths))
	PlayerStateStore.Observe(PlayerStateStore.Fields.Rebirths, function(value, oldValue)
		local nextRebirths = numberValue(value)
		local previousRebirths = tonumber(oldValue)
		if previousRebirths and nextRebirths > previousRebirths then
			lastRebirthIncreaseClock = os.clock()
		end
		latestRebirths = nextRebirths
	end)

	PlayerStateStore.Observe(PlayerStateStore.Fields.Currency, function(value, oldValue)
		local newCurrency = tonumber(value)
		local previousCurrency = tonumber(oldValue)
		if not newCurrency or not previousCurrency or newCurrency >= previousCurrency then
			return
		end

		local rebirthsAtDrop = latestRebirths
		task.delay(REBIRTH_SUPPRESSION_DELAY_SECONDS, function()
			if shouldSuppressForRebirth(rebirthsAtDrop) then
				return
			end
			RuntimeGuard.Run("CurrencySpendSounds.PlayMoneyCollected", SoundEffects.Play, SoundEffects.Names.MoneyCollected)
		end)
	end)
end

return CurrencySpendSounds
