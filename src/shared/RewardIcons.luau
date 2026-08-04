-- Flat 2D reward icons: the one place an rbxassetid for a non-modelled reward
-- lives.
--
-- Rewards split into two rendering families. Anything with a 3D model (seeds,
-- crops, packs, pets, crates) is rendered through ViewportPreview from its own
-- catalog, so it needs no entry here. Everything else -- cash, grow skips,
-- durian tickets -- has no model and is drawn as an ImageLabel, and those ids
-- used to be scattered: cash on ShopBalance, the grow skip nested inside
-- ShopBalance.EndlessPack.Icons, and the durian ticket nowhere in Lua at all
-- (it existed only as an Image property on the Studio-authored ticket art,
-- which meant no new feature could reach it).
--
-- ShopBalance re-exports Cash/CashLarge/GrowSkip from here so the existing
-- callers keep working and each asset id still has exactly one literal.
local RewardIcons = {}

-- Cash: the small coin stack. CashLarge is the fuller pile the Endless Pack
-- uses for its bigger money tier.
RewardIcons.Cash = "rbxassetid://83341129100923"
RewardIcons.CashLarge = "rbxassetid://125623245592194"
RewardIcons.GrowSkip = "rbxassetid://128769188913261"
-- Authored on Menu.DurianPackHolder.DurianPack.TicketHolder.DurianTicket.
RewardIcons.DurianTicket = "rbxassetid://80097979891169"

-- Cash amounts render in this green wherever they are shown as text.
RewardIcons.CashTextColor = Color3.fromRGB(76, 217, 100)

return RewardIcons
