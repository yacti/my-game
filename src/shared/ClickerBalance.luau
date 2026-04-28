-- Balance config for Clicker-class FeedMachines that have an upgrade
-- chain (e.g. AppleTree). Each level dictates which food is dropped and
-- how much it costs to advance to the *next* level. The terminal level
-- has no upgradeCost.
--
-- This module is the single source of truth for clicker-tree economy:
-- chain length, prices, click cooldown, and respawn delay. Per-instance
-- attributes on the template still win when present (so a designer can
-- override clickCooldown on a single AppleTree without editing code),
-- but the defaults live here so adding a new tree variant is a one-place
-- change.
--
-- Shape:
--   CONFIGS[feedType] = {
--     respawnDelay  = number   -- seconds before a dropped slot regrows
--     clickCooldown = number   -- seconds between clicks (per tree)
--     levels = {
--       [n] = { foodType = string, upgradeCost = number? }
--     }
--   }
--
-- Adding another click machine is just another CONFIGS entry.

local ClickerBalance = {}

local CONFIGS = {
	AppleTree = {
		respawnDelay  = 1,
		clickCooldown = 0.5,
		-- 10 placeholder levels, all dropping Food1_Clicker until the
		-- real apple chain is added. Last level has no upgradeCost.
		levels = {
			{ foodType = "Food1_Clicker", upgradeCost = 100   },
			{ foodType = "Food1_Clicker", upgradeCost = 250   },
			{ foodType = "Food1_Clicker", upgradeCost = 500   },
			{ foodType = "Food1_Clicker", upgradeCost = 1000  },
			{ foodType = "Food1_Clicker", upgradeCost = 2000  },
			{ foodType = "Food1_Clicker", upgradeCost = 4000  },
			{ foodType = "Food1_Clicker", upgradeCost = 7500  },
			{ foodType = "Food1_Clicker", upgradeCost = 15000 },
			{ foodType = "Food1_Clicker", upgradeCost = 30000 },
			{ foodType = "Food1_Clicker"                      },
		},
	},
}

function ClickerBalance.Get(feedType)
	return CONFIGS[feedType]
end

function ClickerBalance.MaxLevel(feedType)
	local cfg = CONFIGS[feedType]
	return cfg and #cfg.levels or 1
end

function ClickerBalance.ClampLevel(feedType, level)
	local max = ClickerBalance.MaxLevel(feedType)
	if type(level) ~= "number" or level < 1 then return 1 end
	if level > max then return max end
	return math.floor(level)
end

function ClickerBalance.FoodAt(feedType, level)
	local cfg = CONFIGS[feedType]
	if not cfg then return nil end
	local entry = cfg.levels[ClickerBalance.ClampLevel(feedType, level)]
	return entry and entry.foodType or nil
end

-- Cost to upgrade FROM `level` to `level+1`. Returns nil at max level.
function ClickerBalance.UpgradeCost(feedType, level)
	local cfg = CONFIGS[feedType]
	if not cfg then return nil end
	local entry = cfg.levels[ClickerBalance.ClampLevel(feedType, level)]
	return entry and entry.upgradeCost or nil
end

function ClickerBalance.IsMaxLevel(feedType, level)
	return ClickerBalance.UpgradeCost(feedType, level) == nil
end

return ClickerBalance
