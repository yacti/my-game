-- Alien Stand: the admin-toggled Mr Alien camp (the MrAlienEvent template at
-- ReplicatedStorage.Assets.AdminEvents, cloned into Workspace.Map while the
-- stand is up). It is a durable global toggle in its own right -- the
-- AdminPanel ASTAND ON/OFF buttons, not the Alien invasion event -- so it has
-- no schedule, no timer and no failsafe: it stays up until an operator turns
-- it off, exactly like the admin party pad.
--
-- Players deposit Alien-mutated food into the AlienCrate for tiered seed
-- rewards; per-player progress lives in profile.Data.AlienStand as a single
-- numeric deposit counter (one crate, one mutation), tiers loop 1 -> 2 -> 3 -> 1,
-- and it persists between stand visits. Deposits are only accepted while the
-- stand is up, since the crate does not exist otherwise.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Assets = require(script.Parent:WaitForChild("Assets"))

local AlienStand = {}

-- Master switch: false retires the stand -- the control plane refuses to raise
-- it and the server refuses deposits -- without tearing out the feature or
-- player progress.
AlienStand.Enabled = true

AlienStand.MutationId = "Alien"

-- Required deposits into the crate per tier, and the seed granted on
-- completion. Tiers loop: completing the last tier restarts at 1.
--
-- The Alien-themed EventOnly + Exclusive patch seeds, ordered so reward
-- strength climbs with cost: their authored PercentageOfBest values are
-- AlienEggPatch 1.11, AlienFungusPatch 1.33, EyeshroomPatch 1.66.
AlienStand.Tiers = {
	{ required = 5, rewardSeedId = "AlienEggSeed" },
	{ required = 10, rewardSeedId = "AlienFungusSeed" },
	{ required = 20, rewardSeedId = "EyeshroomSeed" },
}

AlienStand.MaxDepositDistance = 14

-- ReplicatedStorage.Assets.AdminEvents.MrAlienEvent -> Workspace.Map.MrAlienEvent.
-- The template is authored in place (x ~21, z ~-63 to -68, about 56 studs north
-- of Map.CENTER), so the runtime clone keeps its authored CFrames and needs no
-- spawn marker.
AlienStand.AssetsFolderName = Assets.Names.AdminEvents
AlienStand.TemplateName = "MrAlienEvent"
AlienStand.MapFolderName = "Map"

AlienStand.PlatformName = "AlienPlatform"
AlienStand.NpcName = "Alien"
AlienStand.NpcDialogueGuiName = "AlienDialogue"
AlienStand.UfoName = "UFO"
AlienStand.GlowName = "Glow"
AlienStand.CrateName = "AlienCrate"
AlienStand.CrateBodyName = "CrateBody"
AlienStand.CrateFillName = "Fill"
AlienStand.CrateBillboardName = "AlienFoodAmount"
AlienStand.TeleportPartName = "AlienTeleport"

-- Entrance, derived entirely client-side from the ActivatedAt attribute the
-- server stamps on the runtime folder: the UFO drops in from above and
-- everything else fades up under it once it has settled. A player who joins
-- after the window has passed sees the settled stand with no animation.
AlienStand.Entrance = {
	ufoDescendStuds = 150,
	ufoDescendSeconds = 4,
	fadeInSeconds = 1.5,
}

function AlienStand.EntranceTotalSeconds()
	return AlienStand.Entrance.ufoDescendSeconds + AlienStand.Entrance.fadeInSeconds
end

function AlienStand.NormalizeTier(tier)
	tier = tonumber(tier)
	if tier == nil or tier ~= math.floor(tier) then
		return 1
	end
	if AlienStand.Tiers[tier] then
		return tier
	end
	return 1
end

function AlienStand.TierConfig(tier)
	return AlienStand.Tiers[AlienStand.NormalizeTier(tier)]
end

function AlienStand.NextTier(tier)
	tier = AlienStand.NormalizeTier(tier) + 1
	if AlienStand.Tiers[tier] then
		return tier
	end
	return 1
end

function AlienStand.RequiredFor(tier)
	return AlienStand.TierConfig(tier).required
end

function AlienStand.FindTemplate()
	local assets = ReplicatedStorage:FindFirstChild(Assets.FolderName)
	local adminEvents = assets and assets:FindFirstChild(AlienStand.AssetsFolderName)
	return adminEvents and adminEvents:FindFirstChild(AlienStand.TemplateName) or nil
end

function AlienStand.FindMapFolder()
	return Workspace:FindFirstChild(AlienStand.MapFolderName)
end

-- The presence of this folder IS "the stand is up": the server clones it in on
-- the toggle and destroys it on the way out.
function AlienStand.FindRuntimeFolder()
	local map = AlienStand.FindMapFolder()
	return map and map:FindFirstChild(AlienStand.TemplateName) or nil
end

function AlienStand.FindCrate(standFolder)
	standFolder = standFolder or AlienStand.FindRuntimeFolder()
	return standFolder and standFolder:FindFirstChild(AlienStand.CrateName) or nil
end

function AlienStand.FindTeleportPart(standFolder)
	standFolder = standFolder or AlienStand.FindRuntimeFolder()
	local part = standFolder and standFolder:FindFirstChild(AlienStand.TeleportPartName)
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

return AlienStand
