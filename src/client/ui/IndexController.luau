-- Index (collection/codex) menu. Populates the Studio-owned
-- ReplicatedStorage.UI.Menu.Index panel with three tabs (Pets, Trees,
-- Patches), discovered/locked card states driven by the replicated
-- Discovered profile field, rarity-coloured card backgrounds, viewport
-- previews (pets, fruited trees, patches with food), a per-tab discovered
-- counter, and a click-to-inspect info panel. Also owns the topbar Index
-- icon (order 1, between the edit and discord icons).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local Food = require(Shared:WaitForChild("Food"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Rarities = require(Shared:WaitForChild("Rarities"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local State = require(Shared:WaitForChild("State"))
local FeedDisplayModel = require(script.Parent:WaitForChild("FeedDisplayModel"))
local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))
local ViewportPreview = require(script.Parent:WaitForChild("ViewportPreview"))

local IndexController = {}

local PANEL_NAME = "Index"
local GENERATED_ENTRY_ATTR = "IndexGeneratedEntry"
local TOPBAR_INDEX_ICON_NAME = "IndexMenu"
local TOPBAR_INDEX_ICON_IMAGE = "rbxassetid://97660554679830"
local LOCKED_NAME_TEXT = "???"
local LOCKED_STAT_TEXT = "???"
local LOCKED_BACKGROUND_COLOR = Color3.fromRGB(100, 100, 100)
local UNLOCKED_BACKGROUND_COLOR = Color3.fromRGB(255, 255, 255)
local SELECTED_TAB_COLOR = Color3.fromRGB(150, 150, 150)
local UNSELECTED_TAB_COLOR = Color3.fromRGB(255, 255, 255)
local DISCOVERED_TEXT_FORMAT = 'Discovered: <font color="#ABFF00">%d/%d</font>'
local LIVE_XP_REFRESH_SECONDS = 1
local TAB_PETS = "Pets"
local TAB_TREES = "Trees"
local TAB_PATCHES = "Patches"
local TAB_ORDER = { TAB_PETS, TAB_TREES, TAB_PATCHES }
local CLASS_FOR_TAB = { [TAB_TREES] = "Tree", [TAB_PATCHES] = "Patch" }

-- Static previews yaw the model so its front (-Z) points at the viewport
-- camera, which sits on the +X/+Z diagonal.
local FACE_CAMERA_YAW_DEGREES = -135
local GRID_VIEWPORT_OPTIONS = {
	Pet = {
		targetMaxDimension = ViewportPreview.PET_TARGET_MAX_DIMENSION,
		zoom = ViewportPreview.PET_VIEWPORT_ZOOM,
		rotate = false,
		yawDegrees = FACE_CAMERA_YAW_DEGREES,
		-- Pet templates are saved with inconsistent world rotations; align
		-- them to their pivot so one yaw faces every model at the camera.
		alignPivot = true,
	},
	Tree = { zoom = 2, rotate = false, yawDegrees = FACE_CAMERA_YAW_DEGREES },
	-- Patches are wide and flat: zoom out and look down a little so the whole
	-- patch fits instead of cropping to its center.
	Patch = { zoom = 2.1, cameraHeightFactor = 0.6, rotate = false, yawDegrees = FACE_CAMERA_YAW_DEGREES },
}
local INFO_VIEWPORT_OPTIONS = {
	Pet = {
		targetMaxDimension = ViewportPreview.PET_TARGET_MAX_DIMENSION,
		zoom = ViewportPreview.PET_VIEWPORT_ZOOM,
		alignPivot = true,
	},
	Tree = { zoom = 2 },
	Patch = { zoom = 2.1, cameraHeightFactor = 0.6 },
}

local SILHOUETTE_STRIP_CLASSES = {
	"Decal", "Texture", "SurfaceAppearance",
	"ParticleEmitter", "Beam", "Trail", "Fire", "Smoke", "Sparkles",
	"PointLight", "SpotLight", "SurfaceLight",
}

local function requireTopbarIcon()
	local satchelRoot = ReplicatedStorage:WaitForChild("Satchel", 10)
	if not satchelRoot then
		warn("[IndexController] Missing ReplicatedStorage.Satchel; index toolbar icon will not start")
		return nil
	end

	local loader = satchelRoot:WaitForChild("SatchelLoader", 10)
	local satchelModule = loader and loader:WaitForChild("Satchel", 10)
	local packages = satchelModule and satchelModule:WaitForChild("Packages", 10)
	local topbarPlus = packages and packages:WaitForChild("topbarplus", 10)
	if not topbarPlus then
		warn("[IndexController] Missing Satchel TopbarPlus module; index toolbar icon will not start")
		return nil
	end

	return require(topbarPlus)
end

local function validRarityOr(rarity, fallback)
	if type(rarity) == "string" and Rarities.IsValid(rarity) then
		return rarity
	end
	return fallback
end

local function rarityOrderIndex(rarity)
	for index, name in ipairs(Rarities.Order) do
		if name == rarity then
			return index
		end
	end
	return #Rarities.Order + 1
end

-- ── Catalog builders ──────────────────────────────────────────────────────────

local function buildPetEntries()
	local petModels = Assets.Find(Assets.Names.PetModels)
	if not petModels then
		warn("[IndexController] Missing ReplicatedStorage.Assets.PetModels; Pets tab will be empty")
		return {}
	end

	local entries = {}
	for _, template in ipairs(petModels:GetChildren()) do
		if template:IsA("Model") then
			local petId = template:GetAttribute(State.Pet.Id)
			if type(petId) == "string" and petId ~= "" then
				entries[#entries + 1] = {
					kind = "Pet",
					key = "Pet:" .. petId,
					id = petId,
					template = template,
					displayName = template.Name,
					order = tonumber(template:GetAttribute(State.Pet.Order)) or math.huge,
					rarity = validRarityOr(template:GetAttribute(State.Pet.Rarity), Rarities.Common),
					moneyRate = tonumber(template:GetAttribute(State.Pet.MoneyRate)) or 1,
				}
			end
		end
	end
	table.sort(entries, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.id < b.id
	end)
	return entries
end

local function feedClassOf(template)
	local feedClass = template:GetAttribute(State.Feed.Class)
	if type(feedClass) == "string" and feedClass ~= "" then
		return feedClass
	end
	return template.Parent and template.Parent.Name or nil
end

-- Trees/Patches in one pass. Machine templates own behavior attributes;
-- display rarity/roll odds live on the matching seed template (machine
-- ItemRarity attribute wins when present, same precedence as ShovelController).
local function buildFeedEntries()
	local machines = Assets.Find(Assets.Names.FeedMachines)
	if not machines then
		warn("[IndexController] Missing ReplicatedStorage.Assets.FeedMachines; Trees/Patches tabs will be empty")
		return { Tree = {}, Patch = {} }
	end

	local byClass = { Tree = {}, Patch = {} }
	for _, folder in ipairs(machines:GetChildren()) do
		for _, template in ipairs(folder:GetChildren()) do
			if template:IsA("Model") or template:IsA("BasePart") then
				local feedType = template:GetAttribute(State.Feed.Type)
				local class = feedClassOf(template)
				local bucket = type(feedType) == "string" and feedType ~= "" and byClass[class]
				if bucket then
					bucket[#bucket + 1] = {
						kind = "Feed",
						key = "Feed:" .. feedType,
						id = feedType,
						template = template,
						class = class,
						displayName = template.Name,
						rarity = validRarityOr(
							template:GetAttribute(State.Feed.Rarity),
							validRarityOr(Seeds.RarityForFeedType(feedType), Rarities.Common)
						),
						chanceN = Seeds.RollChanceNForFeedType(feedType),
						eventOnly = Seeds.IsEventOnlyFeedType(feedType),
						pct = tonumber(template:GetAttribute(State.Feed.PercentageOfBest)),
						foodDrop = template:GetAttribute(State.Feed.FoodDrop),
						xp = tonumber(template:GetAttribute(State.Feed.XP)),
					}
				end
			end
		end
	end
	for _, entries in pairs(byClass) do
		table.sort(entries, function(a, b)
			local rarityA, rarityB = rarityOrderIndex(a.rarity), rarityOrderIndex(b.rarity)
			if rarityA ~= rarityB then
				return rarityA < rarityB
			end
			local chanceA, chanceB = a.chanceN or math.huge, b.chanceN or math.huge
			if chanceA ~= chanceB then
				return chanceA < chanceB
			end
			return a.displayName < b.displayName
		end)
	end
	return byClass
end

-- All-black neon silhouette for locked entries.
local function applySilhouette(model)
	local function applyToPart(part)
		part.Color = Color3.new(0, 0, 0)
		part.Material = Enum.Material.Neon
		if part:IsA("MeshPart") then
			part.TextureID = ""
		elseif part:IsA("UnionOperation") then
			-- Unions ignore Color unless UsePartColor is on.
			part.UsePartColor = true
		end
	end

	if model:IsA("BasePart") then
		applyToPart(model)
	end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			applyToPart(descendant)
		elseif descendant:IsA("SpecialMesh") then
			descendant.TextureId = ""
		else
			for _, className in ipairs(SILHOUETTE_STRIP_CLASSES) do
				if descendant:IsA(className) then
					descendant:Destroy()
					break
				end
			end
		end
	end
	return model
end

-- ── Controller ────────────────────────────────────────────────────────────────

function IndexController.start()
	local player = Players.LocalPlayer
	local indexFrame = MenuGui.GetFrame(PANEL_NAME, "IndexController")
	if not indexFrame then
		return
	end

	local function resolveChild(parent, childName, className)
		local child = parent and parent:FindFirstChild(childName)
		if child and (className == nil or child:IsA(className)) then
			return child
		end
		warn(string.format(
			"[IndexController] Missing %s.%s (%s); Index menu disabled",
			parent and parent:GetFullName() or "?", childName, tostring(className or "Instance")
		))
		return nil
	end

	local rarityBtns = resolveChild(indexFrame, "RarityBtns", "Frame")
	local indexMain = resolveChild(indexFrame, "IndexMain", "ScrollingFrame")
	local entryTemplate = resolveChild(indexMain, "Template", "Frame")
	local gridLayout = indexMain and indexMain:FindFirstChildOfClass("UIGridLayout")
	if not gridLayout then
		warn("[IndexController] Missing IndexMain UIGridLayout; Index menu disabled")
		return
	end
	local discoveredLabel = resolveChild(indexFrame, "Discovered", "TextLabel")
	local closeButton = resolveChild(indexFrame, "CloseButton", "GuiButton")
	local petInfoFrame = resolveChild(indexFrame, "PetInfoFrame", "Frame")
	local patchTreeInfoFrame = resolveChild(indexFrame, "PatchTreeInfoFrame", "Frame")
	if not (rarityBtns and indexMain and entryTemplate and discoveredLabel and closeButton and petInfoFrame and patchTreeInfoFrame) then
		return
	end

	local tabButtons = {}
	for _, tabName in ipairs(TAB_ORDER) do
		local button = resolveChild(rarityBtns, tabName, "GuiButton")
		local shade = button and resolveChild(button, "Button", "ImageLabel")
		if not (button and shade) then
			return
		end
		tabButtons[tabName] = { button = button, shade = shade }
	end

	entryTemplate.Visible = false

	-- AutomaticCanvasSize under-measures UIGridLayout content and crops the
	-- last row of cards. Scale-based cell heights resolve against the CANVAS,
	-- so manual canvas sizing would feed back into cell size; pin the vertical
	-- grid metrics to window-derived pixel offsets first, then size the canvas
	-- from the laid-out content.
	local authoredCellScaleY = gridLayout.CellSize.Y.Scale
	local authoredCellPadScaleY = gridLayout.CellPadding.Y.Scale
	local authoredPaddingTopScale = 0
	local mainPadding = indexMain:FindFirstChildOfClass("UIPadding")
	if mainPadding then
		authoredPaddingTopScale = mainPadding.PaddingTop.Scale
	end

	local function updateCanvasSize()
		local windowHeight = indexMain.AbsoluteSize.Y
		if windowHeight <= 0 then
			return
		end
		gridLayout.CellSize = UDim2.new(
			gridLayout.CellSize.X.Scale, gridLayout.CellSize.X.Offset,
			0, math.floor(windowHeight * authoredCellScaleY)
		)
		gridLayout.CellPadding = UDim2.new(
			gridLayout.CellPadding.X.Scale, gridLayout.CellPadding.X.Offset,
			0, math.floor(windowHeight * authoredCellPadScaleY)
		)
		local paddingTop = math.ceil(windowHeight * authoredPaddingTopScale)
		if mainPadding then
			mainPadding.PaddingTop = UDim.new(0, paddingTop)
		end
		indexMain.CanvasSize = UDim2.fromOffset(
			0,
			gridLayout.AbsoluteContentSize.Y + paddingTop + math.ceil(windowHeight * 0.03)
		)
	end
	indexMain.AutomaticCanvasSize = Enum.AutomaticSize.None
	RuntimeGuard.Connect(
		gridLayout:GetPropertyChangedSignal("AbsoluteContentSize"),
		"IndexController.CanvasSizeContent",
		updateCanvasSize
	)
	RuntimeGuard.Connect(
		indexMain:GetPropertyChangedSignal("AbsoluteSize"),
		"IndexController.CanvasSizeWindow",
		updateCanvasSize
	)

	-- State
	local panelOpen = false
	local currentTab = TAB_PETS
	local petEntries = nil
	local feedEntries = nil
	local classByFeedType = {}
	local discoveredCache = PlayerStateStore.Get(PlayerStateStore.Fields.Discovered)
	local gridRecords = {} -- array of { entry, frame, locked }
	local selectedRecord = nil
	local displayModelCache = {}
	local silhouetteCache = {}
	local liveXPToken = 0
	local animatedGradients = {} -- [UIGradient] = rarity (Mythical only)
	local animatedLabels = {} -- [TextLabel] = rarity
	local rarityRenderConnection = nil
	local topbarIcon = nil
	local syncingIcon = false

	local selectionStroke = Instance.new("UIStroke")
	selectionStroke.Name = "IndexSelectionStroke"
	selectionStroke.Thickness = 3
	selectionStroke.Color = Color3.fromRGB(255, 255, 255)
	selectionStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

	local function entriesForTab(tabName)
		if tabName == TAB_PETS then
			petEntries = petEntries or buildPetEntries()
			return petEntries
		end
		if not feedEntries then
			feedEntries = buildFeedEntries()
			for _, entries in pairs(feedEntries) do
				for _, entry in ipairs(entries) do
					classByFeedType[entry.id] = entry.class
				end
			end
		end
		return feedEntries[CLASS_FOR_TAB[tabName]] or {}
	end

	local function isUnlocked(entry)
		if type(discoveredCache) ~= "table" then
			return false
		end
		local set = entry.kind == "Pet" and discoveredCache.Pets or discoveredCache.Feed
		return type(set) == "table" and set[entry.id] == true
	end

	-- ── Animated rarity colors (one shared render connection) ─────────────

	-- Two stops sampled a quarter-period apart so animated rarities render as a
	-- moving gradient rather than a flat colour.
	local function animatedGradientSequence(rarity, now)
		local definition = Rarities.Get(rarity)
		local period = definition and (definition.TweenPeriod or definition.RainbowPeriod) or 4
		return ColorSequence.new(
			Rarities.ColorFor(rarity, now),
			Rarities.ColorFor(rarity, now + period * 0.25)
		)
	end

	local function refreshAnimatedRarities()
		local now = os.clock()
		local hasAny = false
		for gradient, rarity in pairs(animatedGradients) do
			if gradient.Parent then
				hasAny = true
				gradient.Color = animatedGradientSequence(rarity, now)
			else
				animatedGradients[gradient] = nil
			end
		end
		for label, rarity in pairs(animatedLabels) do
			if label.Parent then
				hasAny = true
				label.TextColor3 = Rarities.TextColorFor(rarity, now)
			else
				animatedLabels[label] = nil
			end
		end
		if not hasAny and rarityRenderConnection then
			rarityRenderConnection:Disconnect()
			rarityRenderConnection = nil
		end
	end

	local function ensureRarityRender()
		if panelOpen and not rarityRenderConnection
			and (next(animatedGradients) ~= nil or next(animatedLabels) ~= nil) then
			rarityRenderConnection = RuntimeGuard.Connect(
				RunService.RenderStepped,
				"IndexController.RarityRender",
				refreshAnimatedRarities
			)
		end
	end

	local function stopRarityRender()
		if rarityRenderConnection then
			rarityRenderConnection:Disconnect()
			rarityRenderConnection = nil
		end
	end

	-- ── Card backgrounds ──────────────────────────────────────────────────

	local function applyRarityBackground(background, rarity, locked)
		local gradient = background:FindFirstChildOfClass("UIGradient")
		if not gradient then
			gradient = Instance.new("UIGradient")
			gradient.Rotation = 90
			gradient.Parent = background
		end
		animatedGradients[gradient] = nil

		local definition = Rarities.Get(rarity)
		if definition and definition.Animated then
			-- Animated rarities (Mythical, Exclusive) keep animating even on
			-- locked cards; the lock shade comes from ImageColor3 below.
			gradient.Color = animatedGradientSequence(rarity, os.clock())
			animatedGradients[gradient] = rarity
			ensureRarityRender()
		elseif definition and definition.TweenColors then
			-- Non-animated tween rarity: colour stops laid out statically.
			local stops = definition.TweenColors
			local keypoints = {}
			for i, color in ipairs(stops) do
				table.insert(keypoints, ColorSequenceKeypoint.new((i - 1) / (#stops - 1), color))
			end
			gradient.Color = ColorSequence.new(keypoints)
		else
			gradient.Color = ColorSequence.new(Rarities.ColorFor(rarity) or Rarities.ColorFor(Rarities.Common))
		end

		background.ImageColor3 = locked and LOCKED_BACKGROUND_COLOR or UNLOCKED_BACKGROUND_COLOR
	end

	-- ── Viewport models ───────────────────────────────────────────────────

	local function displayModelFor(entry, locked)
		if locked then
			local silhouette = silhouetteCache[entry.key]
			if not silhouette then
				local source = entry.kind == "Pet" and entry.template or FeedDisplayModel.Build(entry.template)
				silhouette = applySilhouette(source:Clone())
				silhouetteCache[entry.key] = silhouette
			end
			return silhouette
		end

		if entry.kind == "Pet" then
			return entry.template
		end
		local model = displayModelCache[entry.key]
		if not model then
			model = FeedDisplayModel.Build(entry.template)
			displayModelCache[entry.key] = model
		end
		return model
	end

	local function viewportKindFor(entry)
		return entry.kind == "Pet" and "Pet" or entry.class
	end

	-- ── Info panel ────────────────────────────────────────────────────────

	local function setLabelText(parent, labelName, text)
		local label = parent:FindFirstChild(labelName)
		if label and (label:IsA("TextLabel") or label:IsA("TextButton")) then
			label.Text = text
			return label
		end
		return nil
	end

	local function applyRarityLabel(parent, rarity)
		local label = setLabelText(parent, "Rarity", rarity)
		if not label then
			return
		end
		animatedLabels[label] = nil
		local definition = Rarities.Get(rarity)
		label.TextColor3 = Rarities.TextColorFor(rarity, os.clock()) or Color3.fromRGB(255, 255, 255)
		if definition and definition.Animated then
			animatedLabels[label] = rarity
			ensureRarityRender()
		end
	end

	local function bestStaticXPForClass(class)
		local plot = PlotResolver.ResolveForPlayer(player)
		if not plot then
			return nil
		end
		local best = nil
		for _, child in ipairs(plot:GetChildren()) do
			if (child:IsA("Model") or child:IsA("BasePart"))
				and type(child:GetAttribute(State.Feed.Type)) == "string"
				and child:GetAttribute(State.Feed.Index) ~= nil
				and child:GetAttribute(State.Seed.Phase) ~= "GrowingSeed"
				and child:GetAttribute(State.Feed.PercentageOfBest) == nil then
				local childClass = child:GetAttribute(State.Feed.Class)
				if type(childClass) ~= "string" or childClass == "" then
					childClass = classByFeedType[child:GetAttribute(State.Feed.Type)]
				end
				if childClass == class then
					local xp = tonumber(child:GetAttribute(State.Feed.XP)) or 1
					if not best or xp > best then
						best = xp
					end
				end
			end
		end
		return best
	end

	local function feedXPText(entry)
		if entry.class == "Tree" then
			-- Tree XP attribute is a per-drop multiplier on the food's own XP.
			local dropXP = Food.BaseXP(entry.foodDrop) * (entry.xp or 1)
			return NumberFormatter.XP(dropXP, "XP per drop")
		end
		return NumberFormatter.XP(entry.xp or 1, "XP per grow")
	end

	-- Mirrors FeedMachines.RecomputeDynamicXP: resolved = max(pct x best
	-- same-class static machine XP on the plot, 1).
	local function liveXPText(entry)
		local best = bestStaticXPForClass(entry.class)
		local resolved = math.max(entry.pct * (best or 0), 1)
		if entry.class == "Tree" then
			return NumberFormatter.XP(Food.BaseXP(entry.foodDrop) * resolved, "XP per drop")
		end
		return NumberFormatter.XP(resolved, "XP per grow")
	end

	local function stopLiveXP()
		liveXPToken += 1
	end

	local function startLiveXP(entry, xpLabel)
		liveXPToken += 1
		local token = liveXPToken
		RuntimeGuard.Spawn("IndexController.LiveXP", function()
			while token == liveXPToken and panelOpen and xpLabel.Parent do
				local text = liveXPText(entry)
				if xpLabel.Text ~= text then
					xpLabel.Text = text
				end
				task.wait(LIVE_XP_REFRESH_SECONDS)
			end
		end)
	end

	local function populateInfoPanel(record)
		stopLiveXP()
		local entry = record.entry
		local locked = record.locked

		if entry.kind == "Pet" then
			petInfoFrame.Visible = true
			patchTreeInfoFrame.Visible = false
			setLabelText(petInfoFrame, "Name", locked and LOCKED_NAME_TEXT or entry.displayName)
			setLabelText(petInfoFrame, "PetOrder", string.format("%d/%d", entry.order, #entriesForTab(TAB_PETS)))
			applyRarityLabel(petInfoFrame, entry.rarity)
			setLabelText(petInfoFrame, "CashEarned",
				locked and LOCKED_STAT_TEXT or (NumberFormatter.Currency(entry.moneyRate) .. "/ second"))
			local icon = petInfoFrame:FindFirstChild("Icon")
			if icon and icon:IsA("ViewportFrame") then
				ViewportPreview.Render(icon, displayModelFor(entry, locked), INFO_VIEWPORT_OPTIONS.Pet)
			end
			return
		end

		petInfoFrame.Visible = false
		patchTreeInfoFrame.Visible = true
		setLabelText(patchTreeInfoFrame, "Name", locked and LOCKED_NAME_TEXT or entry.displayName)
		applyRarityLabel(patchTreeInfoFrame, entry.rarity)

		local chanceLabel = patchTreeInfoFrame:FindFirstChild("Chance")
		if chanceLabel and chanceLabel:IsA("TextLabel") then
			if entry.chanceN then
				chanceLabel.Text = NumberFormatter.ChanceN(entry.chanceN)
				chanceLabel.Visible = true
			elseif entry.eventOnly then
				chanceLabel.Text = "Event"
				chanceLabel.Visible = true
			else
				chanceLabel.Visible = false
			end
		end

		-- PercentageOfBest is static template metadata: shown for Exclusive
		-- (dynamic-XP) items even while undiscovered.
		local pctLabel = patchTreeInfoFrame:FindFirstChild("PercentageOfBest")
		if pctLabel and pctLabel:IsA("TextLabel") then
			if entry.pct then
				pctLabel.Text = string.format(
					"%s%% of your best %s",
					NumberFormatter.Format(entry.pct * 100),
					entry.class == "Tree" and "tree" or "patch"
				)
				pctLabel.Visible = true
			else
				pctLabel.Visible = false
			end
		end

		local xpLabel = patchTreeInfoFrame:FindFirstChild("XP")
		if xpLabel and xpLabel:IsA("TextLabel") then
			if locked then
				xpLabel.Text = LOCKED_STAT_TEXT
			elseif entry.pct then
				xpLabel.Text = liveXPText(entry)
				startLiveXP(entry, xpLabel)
			else
				xpLabel.Text = feedXPText(entry)
			end
		end

		local icon = patchTreeInfoFrame:FindFirstChild("Icon")
		if icon and icon:IsA("ViewportFrame") then
			ViewportPreview.Render(icon, displayModelFor(entry, locked), INFO_VIEWPORT_OPTIONS[entry.class])
		end
	end

	local function selectRecord(record)
		if not record then
			selectedRecord = nil
			selectionStroke.Parent = nil
			return
		end
		selectedRecord = record
		local main = record.frame:FindFirstChild("Main")
		selectionStroke.Parent = main or record.frame
		populateInfoPanel(record)
	end

	-- ── Grid ──────────────────────────────────────────────────────────────

	local function renderEntryFrame(record)
		local entry = record.entry
		local frame = record.frame
		local locked = record.locked

		local nameLabel = frame:FindFirstChild("Name")
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.Text = locked and LOCKED_NAME_TEXT or entry.displayName
		end

		local main = frame:FindFirstChild("Main")
		local background = main and main:FindFirstChild("Background")
		if background and background:IsA("ImageLabel") then
			applyRarityBackground(background, entry.rarity, locked)
		end

		local icon = frame:FindFirstChild("Icon")
		if icon and icon:IsA("ViewportFrame") then
			ViewportPreview.Render(icon, displayModelFor(entry, locked), GRID_VIEWPORT_OPTIONS[viewportKindFor(entry)])
		end
	end

	local function clearGrid()
		stopLiveXP()
		selectionStroke.Parent = nil
		selectedRecord = nil
		gridRecords = {}
		for _, child in ipairs(indexMain:GetChildren()) do
			if child:GetAttribute(GENERATED_ENTRY_ATTR) == true then
				child:Destroy()
			end
		end
	end

	local function updateDiscoveredLabel()
		local entries = entriesForTab(currentTab)
		local found = 0
		for _, entry in ipairs(entries) do
			if isUnlocked(entry) then
				found += 1
			end
		end
		-- The label is a text stack: only rich-text copies get the colored
		-- markup; plain copies (the stroke/shadow layer) get plain text.
		local rich = string.format(DISCOVERED_TEXT_FORMAT, found, #entries)
		local plain = string.format("Discovered: %d/%d", found, #entries)
		local function apply(label)
			if label:IsA("TextLabel") then
				label.Text = label.RichText and rich or plain
			end
		end
		apply(discoveredLabel)
		for _, descendant in ipairs(discoveredLabel:GetDescendants()) do
			apply(descendant)
		end
	end

	local function populateGrid()
		clearGrid()
		for index, entry in ipairs(entriesForTab(currentTab)) do
			local frame = entryTemplate:Clone()
			frame.Name = entry.key
			frame.LayoutOrder = index
			frame:SetAttribute(GENERATED_ENTRY_ATTR, true)
			frame.Active = true
			frame.Visible = true

			local record = { entry = entry, frame = frame, locked = not isUnlocked(entry) }
			gridRecords[#gridRecords + 1] = record
			renderEntryFrame(record)

			RuntimeGuard.Connect(frame.InputBegan, "IndexController.EntryClick", function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch then
					selectRecord(record)
				end
			end)

			frame.Parent = indexMain
		end
		indexMain.CanvasPosition = Vector2.new(0, 0)
		updateCanvasSize()
		updateDiscoveredLabel()
		selectRecord(gridRecords[1])
	end

	local function selectTab(tabName)
		currentTab = tabName
		for name, tab in pairs(tabButtons) do
			tab.shade.ImageColor3 = name == tabName and SELECTED_TAB_COLOR or UNSELECTED_TAB_COLOR
		end
		populateGrid()
	end

	-- Discovered replica changes: flip only the affected cards in place
	-- instead of repopulating (avoids viewport churn), then refresh the
	-- counter and the info panel if the selected entry flipped.
	local function onDiscoveredChanged(newValue)
		discoveredCache = newValue
		if not panelOpen then
			return
		end
		for _, record in ipairs(gridRecords) do
			local locked = not isUnlocked(record.entry)
			if locked ~= record.locked then
				record.locked = locked
				renderEntryFrame(record)
				if record == selectedRecord then
					populateInfoPanel(record)
				end
			end
		end
		updateDiscoveredLabel()
	end

	-- ── Panel wiring ──────────────────────────────────────────────────────

	local function syncTopbarIcon(selected)
		if not topbarIcon then
			return
		end
		syncingIcon = true
		if selected then
			topbarIcon:select()
		else
			topbarIcon:deselect()
		end
		syncingIcon = false
	end

	-- Standard menu-panel open/close tween + sounds (same setup as the shop
	-- panels and RebirthController).
	local panelState = UiEffects.PreparePanel(indexFrame)
	local transitionToken = 0

	-- Clear the info viewports so their turntable render connections stop.
	local function clearInfoViewports()
		local petIcon = petInfoFrame:FindFirstChild("Icon")
		if petIcon and petIcon:IsA("ViewportFrame") then
			ViewportPreview.Render(petIcon, nil)
		end
		local patchIcon = patchTreeInfoFrame:FindFirstChild("Icon")
		if patchIcon and patchIcon:IsA("ViewportFrame") then
			ViewportPreview.Render(patchIcon, nil)
		end
	end

	local function showPanel()
		if panelOpen then
			return
		end
		panelOpen = true
		transitionToken += 1
		selectTab(TAB_PETS)
		UiEffects.PlayOpen(indexFrame, panelState)
		syncTopbarIcon(true)
	end

	local function hidePanel(switching)
		if not panelOpen and not indexFrame.Visible then
			return
		end
		panelOpen = false
		stopLiveXP()
		stopRarityRender()
		transitionToken += 1
		local token = transitionToken
		syncTopbarIcon(false)
		if switching then
			indexFrame.Visible = false
			indexFrame.Position = panelState.closedPosition
			indexFrame.Size = panelState.closedSize
			clearInfoViewports()
			return
		end
		UiEffects.PlayClose(indexFrame, panelState, function()
			if token == transitionToken and not panelOpen then
				indexFrame.Visible = false
				clearInfoViewports()
			end
		end)
	end

	local function refreshPanel()
		if panelOpen then
			onDiscoveredChanged(PlayerStateStore.Get(PlayerStateStore.Fields.Discovered))
		end
	end

	MenuGui.RegisterPanel(PANEL_NAME, {
		open = showPanel,
		close = hidePanel,
		refresh = refreshPanel,
	})

	UiEffects.BindButton(closeButton)
	RuntimeGuard.Connect(closeButton.Activated, "IndexController.CloseActivated", function()
		MenuGui.ClosePanel(PANEL_NAME)
	end)

	for _, tabName in ipairs(TAB_ORDER) do
		local tab = tabButtons[tabName]
		UiEffects.BindButton(tab.button)
		RuntimeGuard.Connect(tab.button.Activated, "IndexController.Tab" .. tabName, function()
			if panelOpen and currentTab ~= tabName then
				selectTab(tabName)
			end
		end)
	end

	PlayerStateStore.Observe(PlayerStateStore.Fields.Discovered, onDiscoveredChanged)

	-- Topbar icon: backpack (-1), index (0), edit (1).
	RuntimeGuard.Spawn("IndexController.TopbarIcon", function()
		local Icon = requireTopbarIcon()
		if not Icon then
			return
		end
		local icon = Icon.new()
			:setName(TOPBAR_INDEX_ICON_NAME)
			:setImage(TOPBAR_INDEX_ICON_IMAGE)
			:setImageScale(0.7)
			:setCaption("Index")
			:setAlignment("Right")
			:setOrder(1)
			:autoDeselect(false)
		icon:modifyTheme({
			{ "IconButton", "BackgroundColor3", Color3.fromRGB(0, 0, 0) },
			{ "IconButton", "BackgroundTransparency", 0.2 },
			{ "IconCorners", "CornerRadius", UDim.new(1, 0) },
			{ "IconSpot", "BackgroundTransparency", 1, "Selected" },
			{ "IconSpotGradient", "Enabled", false, "Selected" },
		})
		RuntimeGuard.Connect(icon.toggled, "IndexController.IconToggled", function(selected, fromSource)
			if syncingIcon or fromSource ~= "User" then
				return
			end
			if selected then
				MenuGui.OpenPanel(PANEL_NAME)
			else
				MenuGui.ClosePanel(PANEL_NAME)
			end
		end)
		topbarIcon = icon
		-- The panel may already be open/closed by the time the icon resolves.
		syncTopbarIcon(MenuGui.IsOpen(PANEL_NAME))
	end)
end

return IndexController
