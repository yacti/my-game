-- Renders 3D seed-pack icons (Studio models under Assets.Misc.SeedPacks) into
-- PackIcon ViewportFrames and animates Main/Highlight part colours for packs
-- configured below. Shared by the RobuxShop seed pack cards, the pack roll
-- reveal, and the standalone Durian Pack UI so every pack icon looks the same.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local ViewportPreview = require(script.Parent:WaitForChild("ViewportPreview"))

local PackIconDisplay = {}

local PACK_ICON_NAME = "PackIcon"
local SEED_PACKS_FOLDER_NAME = "SeedPacks"
-- 3D pack icons: static, dead-on front, no turntable spin.
local PACK_ICON_PREVIEW_OPTIONS = {
	rotate = false,
	yawDegrees = -135,
	zoom = 2.43,
	cameraHeightFactor = 0,
	colorSaturation = 1.2,
	colorBrightness = 1.55,
	lightColor = Color3.fromRGB(255, 255, 255),
}
-- Main/Highlight rarity colour animation (SeedPack stays authored/static).
-- Animated pack models are authored neutral greys with a pure white
-- Highlight2; the animation drives Main at 240/255 effective shading and
-- Highlight with the same gradient shaded down to 200/255, while Highlight2
-- is never touched (always plain white, no gradient). Animations may override
-- the shared period with periodSeconds (the Durian pack runs a slow
-- light-to-deep blue sweep instead of the old rainbow).
local PACK_COLOR_PERIOD_SECONDS = 4
local PACK_MAIN_SHADE = 240 / 255
local PACK_HIGHLIGHT_SHADE = 200 / 255
local PACK_ANIMATION_BRIGHTNESS = 1.55
local PACK_COLOR_ANIMATIONS = {
	EpicSeedPack = { from = Color3.fromRGB(197, 47, 216), to = Color3.fromRGB(56, 0, 198) },
	SecretSeedPack = { from = Color3.fromRGB(255, 255, 255), to = Color3.fromRGB(0, 0, 0) },
	DurianPack = { from = Color3.fromRGB(0, 203, 255), to = Color3.fromRGB(0, 85, 255), periodSeconds = 12 },
}

local function findDescendant(root, name, className)
	if not root then
		return nil
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant.Name == name and (not className or descendant:IsA(className)) then
			return descendant
		end
	end
	return nil
end

function PackIconDisplay.ModelFor(packId)
	local misc = Assets.Find(Assets.Names.Misc)
	local packsFolder = misc and misc:FindFirstChild(SEED_PACKS_FOLDER_NAME)
	local model = packsFolder and type(packId) == "string" and packsFolder:FindFirstChild(packId) or nil
	if model and model:IsA("Model") then
		return model
	end
	return nil
end

-- One shared heartbeat animates Main/Highlight in every live pack-icon
-- viewport clone; it exists only while animated entries do, and prunes
-- entries whose clones were destroyed (viewport re-render or UI teardown).
local animatedPackEntries = {}
local packAnimationConnection = nil

local function stopPackAnimationIfIdle()
	if packAnimationConnection and next(animatedPackEntries) == nil then
		packAnimationConnection:Disconnect()
		packAnimationConnection = nil
	end
end

local function packAnimationColor(animation, timeSeconds)
	local period = animation.periodSeconds or PACK_COLOR_PERIOD_SECONDS
	local alpha = 0.5 + 0.5 * math.sin(timeSeconds * math.pi * 2 / period)
	local color = animation.from:Lerp(animation.to, alpha)
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(h, s, math.clamp(v * PACK_ANIMATION_BRIGHTNESS, 0, 1))
end

local function shadedColor(color, shade)
	return Color3.new(color.R * shade, color.G * shade, color.B * shade)
end

local function ensurePackAnimationLoop()
	if packAnimationConnection then
		return
	end
	packAnimationConnection = RuntimeGuard.Connect(RunService.Heartbeat, "PackIconDisplay.PackColors", function()
		local now = os.clock()
		for entry in pairs(animatedPackEntries) do
			if not (entry.main.Parent and (not entry.highlight or entry.highlight.Parent)) then
				animatedPackEntries[entry] = nil
			else
				local color = packAnimationColor(entry.animation, now)
				entry.main.Color = shadedColor(color, PACK_MAIN_SHADE)
				if entry.highlight then
					entry.highlight.Color = shadedColor(color, PACK_HIGHLIGHT_SHADE)
				end
			end
		end
		stopPackAnimationIfIdle()
	end)
end

local function registerPackAnimation(viewport, packId)
	local animation = PACK_COLOR_ANIMATIONS[packId]
	if not animation then
		return
	end
	local world = viewport:FindFirstChildOfClass("WorldModel")
	local main = world and world:FindFirstChild("Main", true)
	local highlight = world and world:FindFirstChild("Highlight", true)
	if not (main and main:IsA("BasePart")) then
		return
	end
	animatedPackEntries[{
		main = main,
		highlight = highlight and highlight:IsA("BasePart") and highlight or nil,
		animation = animation,
	}] = true
	ensurePackAnimationLoop()
end

-- Renders the pack model into an explicit ViewportFrame (e.g. the HUD Durian
-- Pack entry, whose viewport is not named PackIcon).
function PackIconDisplay.RenderViewport(viewport, packId)
	if not (viewport and viewport:IsA("ViewportFrame")) then
		return false
	end
	viewport.ImageTransparency = 0
	local rendered = ViewportPreview.Render(viewport, PackIconDisplay.ModelFor(packId), PACK_ICON_PREVIEW_OPTIONS)
	if rendered then
		registerPackAnimation(viewport, packId)
	else
		warn("[PackIconDisplay] Missing SeedPacks model for pack " .. tostring(packId))
	end
	return rendered ~= nil and rendered ~= false
end

-- Finds the PackIcon ViewportFrame under container and renders packId into it.
function PackIconDisplay.Render(container, packId)
	local icon = findDescendant(container, PACK_ICON_NAME, "ViewportFrame")
	if not icon then
		warn("[PackIconDisplay] Missing " .. PACK_ICON_NAME .. " ViewportFrame for pack " .. tostring(packId))
		return false
	end
	return PackIconDisplay.RenderViewport(icon, packId)
end

return PackIconDisplay
