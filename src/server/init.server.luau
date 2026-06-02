local Players             = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")

local Server            = ServerScriptService:WaitForChild("Server")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Remotes           = require(Shared:WaitForChild("Remotes"))
Remotes.validateAll()

require(Server:WaitForChild("AssetValidator")).validate()

local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService       = require(Server:WaitForChild("PlotService"))
local PlotGridService   = require(Server:WaitForChild("PlotGridService"))
local PetMotionService  = require(Server:WaitForChild("PetMotionService"))
local CurrencyService   = require(Server:WaitForChild("CurrencyService"))
local FeedMachines      = require(Server:WaitForChild("feedMachines"))
local FeedMachineTools  = require(Server:WaitForChild("FeedMachineTools"))
local FeedEditService   = require(Server:WaitForChild("FeedEditService"))
local FeedGrowthService = require(Server:WaitForChild("FeedGrowthService"))
local FeedPlacementService = require(Server:WaitForChild("FeedPlacementService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local PromptInteractionService = require(Server:WaitForChild("PromptInteractionService"))
local RebirthService    = require(Server:WaitForChild("RebirthService"))
local ReceiptService    = require(Server:WaitForChild("ReceiptService"))
local RollService       = require(Server:WaitForChild("RollService"))
local SeedTools         = require(Server:WaitForChild("SeedTools"))
local ShovelService     = require(Server:WaitForChild("ShovelService"))
local ShovelTools       = require(Server:WaitForChild("ShovelTools"))
local TelemetryService  = require(Server:WaitForChild("TelemetryService"))

local Interactions = require(Shared:WaitForChild("Interactions"))
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
local State    = require(Shared:WaitForChild("State"))
local Food     = require(Shared:WaitForChild("Food"))

local CurrencyUpdated  = Remotes.get(Remotes.Names.CurrencyUpdated)
local GridUnlockEffect = Remotes.get(Remotes.Names.GridUnlockEffect)

local PROMPT_RATE_SECONDS = 0.12
local PLACE_RATE_SECONDS = 0.25
local PET_COLLECTION_DISTANCE = 5
local PET_COLLECTION_INTERVAL = 0.25
local PET_FEED_REACTION_SECONDS = 2
local PET_FEED_PROMPT_DISTANCE = 8
local PET_EVOLUTION_IDLE_HOLD_SECONDS = 4
local FOOD_PICKUP_PROMPT_DISTANCE = 8
local EDIT_MODE_ATTR = "EditMode"

PlotGridService.ResetVacantPlotsToPreviewRows()
PlotService.SyncVacantPlotVisibility()

RebirthService.Start()
ReceiptService.Start({
	rebirthService = RebirthService,
})
RollService.Start()

-- ── Pet state save ────────────────────────────────────────────────────────────

-- Rebuild profile.Data.Pets from the current plot state (source of truth is the
-- spawned Models and their attributes). Preserves xp/money from the existing
-- profile entry when possible; falls back to 0.
local function savePetsFromPlot(plot, profile)
	local floor = PlotService.GetFloor(plot)
	local saved = {}
	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		local idx = pet:GetAttribute(State.Pet.Index)
		if idx then
			local existing = profile.Data.Pets and profile.Data.Pets[idx] or nil
			local entry = {
				petId = pet:GetAttribute(State.Pet.Id) or (existing and existing.petId) or "Pet1",
				xp    = existing and existing.xp or 0,
				money = existing and existing.money or 0,
			}
			-- Position + rotation are stored in floor-local space so they
			-- survive Floor rotations / translations between sessions.
			if floor then
				local lx, lz, lry = PlotService.WorldPivotToFloorLocal(floor, PetMotionService.GetLogicalPivot(pet))
				entry.lx, entry.lz, entry.lry = lx, lz, lry
			end
			saved[idx] = entry
		end
	end
	profile.Data.Pets = saved
end

-- ── Feed state save ───────────────────────────────────────────────────────────

local function saveFeedState(plot, player, profile)
	local floor = PlotService.GetFloor(plot)
	local placements = {}
	if floor then
		for _, f in ipairs(PlotService.GetSortedFeeds(plot)) do
			-- GetPivot works uniformly for BasePart and Model. We store the
			-- pivot in the floor's local frame (lx/lz/lry) so placements
			-- survive Floor rotations / translations.
			local lx, lz, lry = PlotService.WorldPivotToFloorLocal(floor, f:GetPivot())
			local feedType = f:GetAttribute(State.Feed.Type)
			if type(feedType) ~= "string" or feedType == "" then
				continue
			end
			local rec = {
				type = feedType,
				lx   = lx,
				lz   = lz,
				lry  = lry,
			}
			-- Per-class extras (or growing-seed state). Merged shallow.
			local extras = FeedGrowthService.IsGrowing(f)
				and FeedGrowthService.Serialize(f)
				or FeedMachines.Serialize(f)
			if type(extras) == "table" then
				for k, v in pairs(extras) do rec[k] = v end
			end
			table.insert(placements, rec)
		end
	end
	profile.Data.FeedPlacements = placements

	local feedInventory = {}
	local function captureTool(item)
		if not FeedMachineTools.IsFeedTool(item) then return end
		local ft = item:GetAttribute(State.Feed.Type)
		feedInventory[ft] = (feedInventory[ft] or 0) + 1
	end
	for _, item in pairs(player.Backpack:GetChildren()) do captureTool(item) end
	if player.Character then
		captureTool(player.Character:FindFirstChildWhichIsA("Tool"))
	end
	profile.Data.FeedInventory = feedInventory
	profile.Data.SeedInventory = SeedTools.CountBySeed(player)

	profile.Data.FoodInventory = Food.CountByType(player)
end

local function snapshotProfileState(player, plot, profile)
	if not plot or not profile then return end
	savePetsFromPlot(plot, profile)
	saveFeedState(plot, player, profile)
	profile.Data.LastSeen = os.time()
end

local function notifyGrown(player, feed)
	if not (player and feed) then return end
	NotificationService.Success(player, string.format("%s has grown!", feed.Name))
end

FeedGrowthService.Start({
	onMature = function(player, plot, matureFeed)
		notifyGrown(player, matureFeed)
		PetMotionService.RefreshPlotRoutes(plot)
		local profile = PlayerDataService.GetProfile(player)
		if profile then
			snapshotProfileState(player, plot, profile)
		end
	end,
})

-- ── Pet state replication ────────────────────────────────────────────────────
-- Per-pet state is published as attributes on the pet Model. Clients subscribe
-- via GetAttributeChangedSignal and render billboards locally (see
-- src/client/ui/PetBillboards.luau). No UI is created server-side.

local function publishPetState(pet, money, xp)
	pet:SetAttribute(State.Pet.Money, money or 0)
	pet:SetAttribute(State.Pet.XP,    xp or 0)
end

local function publishPetEvolutionCue(pet, oldPetId, oldScale, pivot, seq)
	pet:SetAttribute(State.Pet.EvolutionOldPetId, oldPetId)
	pet:SetAttribute(State.Pet.EvolutionOldScale, oldScale)
	pet:SetAttribute(State.Pet.EvolutionPivot, pivot)
	pet:SetAttribute(State.Pet.EvolutionSeq, seq)

	task.delay(8, function()
		if pet.Parent and pet:GetAttribute(State.Pet.EvolutionSeq) == seq then
			-- Keep the sequence monotonic, but remove stale payload so late
			-- clients do not replay an already-finished evolution.
			pet:SetAttribute(State.Pet.EvolutionOldPetId, nil)
			pet:SetAttribute(State.Pet.EvolutionOldScale, nil)
			pet:SetAttribute(State.Pet.EvolutionPivot, nil)
		end
	end)
end

-- ── Pet feeding + evolution ──────────────────────────────────────────────────

local function tryEvolvePet(plot, pet, profile)
	local idx = pet:GetAttribute(State.Pet.Index)
	local petData = profile.Data.Pets[idx]
	if not petData then return end

	local activePet = pet
	local evolved = false
	local firstPetId = nil
	local firstScale = nil
	local firstPivot = nil
	local evolutionSeq = nil

	while activePet and activePet.Parent do
		local petId = activePet:GetAttribute(State.Pet.Id)
		local maxXP = activePet:GetAttribute(State.Pet.MaxXP)
		local currentXP = petData.xp or 0
		if type(maxXP) ~= "number" or maxXP <= 0 then
			petData.xp = 0
			break
		end

		if currentXP < maxXP then
			break
		end

		local nextPetId = PetCatalog.NextPetId(petId)
		if not nextPetId then
			petData.xp = math.min(currentXP, maxXP)
			break
		end

		if not firstPetId then
			firstPetId = petId
			firstScale = activePet:GetScale()
			firstPivot = PetMotionService.GetLogicalPivot(activePet)
			evolutionSeq = (activePet:GetAttribute(State.Pet.EvolutionSeq) or 0) + 1
		end

		local evolutionPivot = PetMotionService.GetLogicalPivot(activePet)
		local currentVisual = PetCatalog.VisualForPetId(petId)
		local nextVisual = PetCatalog.VisualForPetId(nextPetId)
		local nextXP = math.max(currentXP - maxXP, 0)

		if currentVisual and nextVisual and currentVisual.ModelName == nextVisual.ModelName then
			if not PlotService.ApplyPetIdAttributes(activePet, nextPetId) then
				break
			end
		else
			local newPet = PlotService.ReplacePetAt(plot, activePet, nextPetId, idx, nextXP, evolutionPivot)
			if not newPet then
				return nil, evolved
			end
			activePet = newPet
			PetMotionService.Register(plot, activePet)
		end

		petData.petId = nextPetId
		petData.xp = nextXP
		evolved = true
	end

	if not activePet or not activePet.Parent then return nil, evolved end

	local logicalPivot = PetMotionService.GetLogicalPivot(activePet)
	PlotService.RescalePet(activePet, petData.xp, logicalPivot)
	publishPetState(activePet, petData.money, petData.xp)

	if evolved then
		publishPetEvolutionCue(activePet, firstPetId, firstScale, firstPivot, evolutionSeq)
	end

	return activePet, evolved
end

local function primaryPartOf(instance)
	if not instance then return nil end
	if instance:IsA("BasePart") then return instance end
	if instance:IsA("Model") then return instance.PrimaryPart end
	return nil
end

local function positionOfInstance(instance)
	if instance and instance:IsA("Model") and instance:GetAttribute(State.Pet.Index) ~= nil then
		return PetMotionService.GetLogicalPosition(instance)
	end

	local primary = primaryPartOf(instance)
	return primary and primary.Position or nil
end

local function isPlayerNearInstance(player, instance, maxDistance)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local position = positionOfInstance(instance)
	return root ~= nil
		and root:IsA("BasePart")
		and position ~= nil
		and (root.Position - position).Magnitude <= maxDistance
end

local function playerFloorLocal(plot, player)
	local floor = PlotService.GetFloor(plot)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (floor and root and root:IsA("BasePart")) then return nil, nil end

	local faceLX, faceLZ = PlotService.WorldPivotToFloorLocal(floor, root.CFrame)
	return faceLX, faceLZ
end

local function triggerPetFeedReaction(pet, faceLX, faceLZ)
	if type(faceLX) ~= "number" or type(faceLZ) ~= "number" then return end

	local seq = (pet:GetAttribute(State.Pet.FeedReactionSeq) or 0) + 1
	local direction = seq % 2 == 0 and 1 or -1

	pet:SetAttribute(State.Pet.FeedReactionSeq, seq)
	pet:SetAttribute(State.Pet.FeedReactionStartTime, workspace:GetServerTimeNow())
	pet:SetAttribute(State.Pet.FeedReactionDuration, PET_FEED_REACTION_SECONDS)
	pet:SetAttribute(State.Pet.FeedReactionDirection, direction)
	pet:SetAttribute(State.Pet.FeedReactionFaceLX, faceLX)
	pet:SetAttribute(State.Pet.FeedReactionFaceLZ, faceLZ)
end

local function feedPet(plot, player, profile, pet)
	if not pet or not pet:IsA("Model") or not pet:IsDescendantOf(plot) then return end
	local primary = pet.PrimaryPart
	if not primary then return end
	if player:GetAttribute("EditMode") == true then return end
	if not isPlayerNearInstance(player, pet, PET_FEED_PROMPT_DISTANCE) then return end

	local idx = pet:GetAttribute(State.Pet.Index)
	local petData = profile.Data.Pets[idx]
	if not petData then return end

	local maxXP = pet:GetAttribute(State.Pet.MaxXP)
	if type(maxXP) ~= "number" or maxXP <= 0 then return end
	if (petData.xp or 0) >= maxXP and PetCatalog.NextPetId(pet:GetAttribute(State.Pet.Id)) == nil then return end

	local food = Food.FindForPetFeed(player)
	if not food then return end

	local foodXP = Food.XPOf(food)
	if not foodXP then return end
	food:Destroy()

	petData.xp = (petData.xp or 0) + foodXP
	local activePet = pet
	local evolved = false
	if petData.xp >= maxXP then
		activePet, evolved = tryEvolvePet(plot, pet, profile)
		if not activePet or not activePet.Parent then return end
	else
		local logicalPivot = PetMotionService.GetLogicalPivot(pet)
		PlotService.RescalePet(pet, petData.xp, logicalPivot)
		pet:SetAttribute(State.Pet.XP, petData.xp)
	end
	local faceLX, faceLZ = playerFloorLocal(plot, player)
	PetMotionService.HoldAfterFeed(activePet, faceLX, faceLZ, evolved and PET_EVOLUTION_IDLE_HOLD_SECONDS or nil)
	triggerPetFeedReaction(activePet, faceLX, faceLZ)
end

-- ── Currency / offline helpers ────────────────────────────────────────────────

local function applyOfflineEarnings(plot, profile)
	local lastSeen = profile.Data.LastSeen or 0
	if lastSeen == 0 then return end
	local elapsed = os.time() - lastSeen
	if elapsed <= 0 then return end

	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		local idx = pet:GetAttribute(State.Pet.Index)
		local petData = profile.Data.Pets[idx]
		if petData then
			local rate = pet:GetAttribute(State.Pet.MoneyRate) or 1
			petData.money = (petData.money or 0) + rate * elapsed
		end
	end
end

local function startPetMoneyLoop(player, plot, profile)
	task.spawn(function()
		while PlotService.GetPlayerPlot(player) == plot do
			task.wait(1)
			for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
				local idx = pet:GetAttribute(State.Pet.Index)
				local petData = profile.Data.Pets[idx]
				if petData then
					local rate = pet:GetAttribute(State.Pet.MoneyRate) or 1
					petData.money = (petData.money or 0) + rate
					pet:SetAttribute(State.Pet.Money, petData.money)
				end
			end
		end
	end)
end

local function startPetCollectionLoop(player, plot, profile)
	task.spawn(function()
		while PlotService.GetPlayerPlot(player) == plot do
			task.wait(PET_COLLECTION_INTERVAL)
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not (root and root:IsA("BasePart")) then
				continue
			end

			for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
				local idx = pet:GetAttribute(State.Pet.Index)
				local petData = profile.Data.Pets[idx]
				if not petData then
					continue
				end

				local money = petData.money or 0
				if money < 1 then
					continue
				end

				local petPosition = PetMotionService.GetLogicalPosition(pet)
				if (root.Position - petPosition).Magnitude <= PET_COLLECTION_DISTANCE then
					CurrencyService.Add(player, profile, money)
					petData.money = 0
					pet:SetAttribute(State.Pet.Money, 0)
				end
			end
		end
	end)
end

local function startProfileSnapshotLoop(player, plot, profile)
	task.spawn(function()
		while PlotService.GetPlayerPlot(player) == plot and PlayerDataService.GetProfile(player) == profile do
			task.wait(60)
			if PlotService.GetPlayerPlot(player) == plot and PlayerDataService.GetProfile(player) == profile then
				snapshotProfileState(player, plot, profile)
			end
		end
	end)
end

local function unlockGridPart(target, plot, player, profile)
	local gridPart = PlotGridService.ResolveGridPart(target)
	local ok, code, _, price = PlotGridService.TryPurchaseCell(player, plot, profile, target)
	if not ok then
		if code ~= "already-unlocked" and code ~= "busy" then
			TelemetryService.Warn("grid_unlock_failed", TelemetryService.ForPlayer(player, {
				reason = code,
				target = target,
				plot = plot,
			}))
		end
		if code == "already-unlocked" then
			NotificationService.Info(player, "That plot area is already unlocked.")
		elseif code == "insufficient-currency" then
			NotificationService.Error(player, "Not enough currency for this plot area.")
		elseif code ~= "busy" then
			NotificationService.Error(player, "Could not unlock that plot area.")
		end
		return
	end

	PetMotionService.RefreshPlotRoutes(plot)
	if gridPart then
		GridUnlockEffect:FireAllClients(gridPart)
	end
	TelemetryService.Record("grid_unlock_succeeded", TelemetryService.ForPlayer(player, {
		price = price,
		gridPart = gridPart,
		plot = plot,
		currency = profile.Data.Currency,
	}))
	NotificationService.Success(player, "Plot area unlocked for $" .. tostring(price) .. "!")
end

-- ── Player lifecycle ──────────────────────────────────────────────────────────

Players.PlayerAdded:Connect(function(player)
	player:SetAttribute(EDIT_MODE_ATTR, false)

	local plot, _ = PlotService.AssignPlot(player)
	if not plot then
		player:Kick("The server is full (all plots are taken).")
		return
	end
	player:SetAttribute(State.Player.AssignedPlotName, plot.Name)
	PlotGridService.ResetPlotState(plot)
	RollService.ApplyDropAreaVisibility(plot, 0)

	local spawnLocation = plot:FindFirstChild("SpawnLocation")
	if spawnLocation then player.RespawnLocation = spawnLocation end

	local profile = PlayerDataService.LoadPlayerAsync(player)
	if not profile then
		player:SetAttribute(State.Player.AssignedPlotName, nil)
		PlotGridService.ResetVacantPlotState(plot)
		PlotService.FreePlot(player)
		return
	end

	local applied, applyReason = PlotGridService.ApplyProfileState(plot, profile)
	if not applied then
		warn(string.format("[init] Failed to apply %s plot grid state: %s", player.Name, tostring(applyReason)))
		PlotGridService.ResetPlotState(plot)
	end
	RollService.ApplyDropAreaVisibility(plot, profile)

	PlotService.SpawnPetsForPlot(plot, profile.Data.Pets)
	local maturedOnLoad = {}
	for index, placement in ipairs(profile.Data.FeedPlacements or {}) do
		if type(placement) == "table" and placement.phase == FeedGrowthService.Phase then
			local restored, status = FeedGrowthService.RestorePlacement(plot, player, placement, index)
			if restored and status == "mature" then
				maturedOnLoad[#maturedOnLoad + 1] = restored
			end
		else
			PlotService.PlaceFeedWithIndex(plot, placement.type, index, placement.lx or 0, placement.lz or 0, placement.lry or 0)
		end
	end

	for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
		if FeedGrowthService.IsGrowing(feed) then
			continue
		end
		FeedMachines.Setup(feed, plot, player)
		local idx   = feed:GetAttribute(State.Feed.Index)
		local saved = idx and profile.Data.FeedPlacements[idx] or nil
		if saved and saved.phase ~= FeedGrowthService.Phase then FeedMachines.Apply(feed, saved) end
	end
	for _, feed in ipairs(maturedOnLoad) do
		task.defer(function()
			notifyGrown(player, feed)
		end)
	end

	applyOfflineEarnings(plot, profile)

	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		local idx = pet:GetAttribute(State.Pet.Index)
		local petData = profile.Data.Pets[idx]
		local money = petData and petData.money or 0
		local xp = petData and petData.xp or 0
		publishPetState(pet, money, xp)
		PetMotionService.Register(plot, pet)
	end

	startPetMoneyLoop(player, plot, profile)
	startPetCollectionLoop(player, plot, profile)
	startProfileSnapshotLoop(player, plot, profile)
	CurrencyUpdated:FireClient(player, profile.Data.Currency or 0)
	RebirthService.SendState(player)
	RollService.SendLuckState(player, profile)
	RollService.SendDropAreaState(player, profile)

	local toolsRestored = false
	local function onCharacterAdded(character)
		ShovelTools.EnsureUtilityTool(player)
		if not toolsRestored then
			toolsRestored = true
			task.wait(0.5)
			for foodType, count in pairs(profile.Data.FoodInventory or {}) do
				for _ = 1, count do
					local tool = Food.MakeTool(foodType)
					if tool then tool.Parent = player.Backpack end
				end
			end
			for feedType, count in pairs(profile.Data.FeedInventory or {}) do
				if type(count) == "number" then
					for _ = 1, count do
						local tool = FeedMachineTools.MakeFeedTool(feedType)
						if tool then tool.Parent = player.Backpack end
					end
				end
			end
			for seedId, count in pairs(profile.Data.SeedInventory or {}) do
				if type(count) == "number" then
					for _ = 1, count do
						local tool = SeedTools.MakeSeedTool(seedId)
						if tool then tool.Parent = player.Backpack end
					end
				end
			end
		end
	end

	if player.Character then onCharacterAdded(player.Character) end
	player.CharacterAdded:Connect(onCharacterAdded)
end)

Players.PlayerRemoving:Connect(function(player)
	local plot = PlotService.GetPlayerPlot(player)
	if plot then
		local profile = PlayerDataService.GetProfile(player)
		if profile then
			snapshotProfileState(player, plot, profile)
		end

		PetMotionService.UnregisterPlot(plot)
		PlotService.DestroyPets(plot)
		-- Destroying the feed parts fires Destroying on each, which the
		-- FeedMachines registry relies on to tear down per-class state
		-- (and to despawn any food the machine spawned on the floor).
		PlotService.DestroyFeeds(plot)
		PlotGridService.ResetVacantPlotState(plot)
		PlotService.FreePlot(player)
	end
	player:SetAttribute(State.Player.AssignedPlotName, nil)
	player:SetAttribute(EDIT_MODE_ATTR, false)

	PlayerDataService.UnloadPlayer(player)
end)

game:BindToClose(function()
	for _, player in pairs(Players:GetPlayers()) do
		local plot    = PlotService.GetPlayerPlot(player)
		local profile = PlayerDataService.GetProfile(player)
		if plot and profile then
			snapshotProfileState(player, plot, profile)
		end
		PlayerDataService.UnloadPlayer(player)
	end

	-- Wait for ProfileStore sessions to finish their final save.
	local deadline = os.clock() + 25
	while PlayerDataService.ActiveProfileCount() > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end)

PromptInteractionService.Start({
	rateSeconds = PROMPT_RATE_SECONDS,
	getContext = function(player)
		return PlotService.GetPlayerPlot(player), PlayerDataService.GetProfile(player)
	end,
	handlers = {
		[Interactions.Actions.PetFeed] = function(player, target, plot, profile)
			feedPet(plot, player, profile, target)
		end,
		[Interactions.Actions.FeedMachine] = function(player, target, plot)
			if target:IsDescendantOf(plot) and isPlayerNearInstance(player, target, 14) then
				FeedMachines.Interact(target, player)
			end
		end,
		[Interactions.Actions.PatchHarvest] = function(player, target, plot)
			if target:IsDescendantOf(plot) and isPlayerNearInstance(player, target, 14) then
				FeedMachines.HarvestPatchAnchor(target, player)
			end
		end,
		[Interactions.Actions.TreeGroundPickup] = function(player, target, plot)
			if target:IsDescendantOf(plot) and isPlayerNearInstance(player, target, FOOD_PICKUP_PROMPT_DISTANCE) then
				FeedMachines.PickupTreeGround(target, player)
			end
		end,
		[Interactions.Actions.GridPartUnlock] = function(player, target, plot, profile)
			unlockGridPart(target, plot, player, profile)
		end,
		[Interactions.Actions.CrateRoll] = function(player, target, plot, profile)
			local ok, code = RollService.Roll(player, target, plot, profile)
			if not ok and code ~= "cooldown" and code ~= "busy" then
				NotificationService.Error(player, "Could not roll that crate.")
			end
		end,
	},
	afterInteraction = function(player, plot, profile)
		snapshotProfileState(player, plot, profile)
	end,
})

FeedEditService.Start({
	snapshotProfileState = snapshotProfileState,
})

ShovelService.Start({
	snapshotProfileState = snapshotProfileState,
})

FeedPlacementService.Start({
	rateSeconds = PLACE_RATE_SECONDS,
	snapshotProfileState = snapshotProfileState,
})
