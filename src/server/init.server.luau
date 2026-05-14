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
local FeedMachines      = require(Server:WaitForChild("feedMachines"))

local Balance  = require(Shared:WaitForChild("Balance"))
local Interactions = require(Shared:WaitForChild("Interactions"))
local State    = require(Shared:WaitForChild("State"))
local Food     = require(Shared:WaitForChild("Food"))

local CurrencyUpdated  = Remotes.get(Remotes.Names.CurrencyUpdated)
local PlaceFeedMachine = Remotes.get(Remotes.Names.PlaceFeedMachine)
local PromptInteract   = Remotes.get(Remotes.Names.PromptInteract)

local petConnections = {}
local promptLastFire = {}
local promptLocks = {}
local placeLastFire = {}
local placeLocks = {}

local PROMPT_RATE_SECONDS = 0.12
local PLACE_RATE_SECONDS = 0.25

-- ── Tool factories ────────────────────────────────────────────────────────────

local function makeFeedTool(feedType)
	local tool = ReplicatedStorage:WaitForChild("FeedMachineTool"):Clone()
	local template = FeedMachines.GetTemplate(feedType)
	tool.Name = template and template.Name or feedType
	tool:SetAttribute(State.Feed.Type, feedType)
	return tool
end

local function isFeedTool(item)
	return item and item:IsA("Tool") and item:GetAttribute(State.Feed.Type) ~= nil
end

local function consumeRateLimit(map, player, interval)
	local now = os.clock()
	local previous = map[player] or 0
	if now - previous < interval then return false end
	map[player] = now
	return true
end

local function withPlayerLock(map, player, callback)
	if map[player] then return end
	map[player] = true
	local ok, err = pcall(callback)
	map[player] = nil
	if not ok then
		warn(err)
	end
end

local function isFinite(n)
	return type(n) == "number" and n == n and math.abs(n) < math.huge
end

local function isValidCFrame(value)
	if typeof(value) ~= "CFrame" then return false end
	local components = { value:GetComponents() }
	for _, component in ipairs(components) do
		if not isFinite(component) then return false end
	end
	return true
end

-- ── Pet state save ────────────────────────────────────────────────────────────

-- Rebuild profile.Data.Pets from the current plot state (source of truth is the
-- spawned Models and their attributes). Preserves xp/money from the existing
-- profile entry when possible; falls back to 0.
local function savePetsFromPlot(plot, profile)
	local floor = plot:FindFirstChild("Floor")
	local saved = {}
	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		local idx = pet:GetAttribute(State.Pet.Index)
		if idx then
			local existing = profile.Data.Pets and profile.Data.Pets[idx] or nil
			local entry = {
				type  = pet:GetAttribute(State.Pet.Type) or (existing and existing.type) or "Pet1",
				xp    = existing and existing.xp or 0,
				money = existing and existing.money or 0,
			}
			-- Position + rotation are stored in floor-local space so they
			-- survive Floor rotations / translations between sessions.
			if floor then
				local lx, lz, lry = PlotService.WorldPivotToFloorLocal(floor, pet:GetPivot())
				entry.lx, entry.lz, entry.lry = lx, lz, lry
			end
			saved[idx] = entry
		end
	end
	profile.Data.Pets = saved
end

-- ── Feed state save ───────────────────────────────────────────────────────────

local function saveFeedState(plot, player, profile)
	local floor = plot:FindFirstChild("Floor")
	local placements = {}
	if floor then
		for _, f in ipairs(PlotService.GetSortedFeeds(plot)) do
			-- GetPivot works uniformly for BasePart and Model. We store the
			-- pivot in the floor's local frame (lx/lz/lry) so placements
			-- survive Floor rotations / translations.
			local lx, lz, lry = PlotService.WorldPivotToFloorLocal(floor, f:GetPivot())
			local rec = {
				type = f:GetAttribute(State.Feed.Type) or f.Name,
				lx   = lx,
				lz   = lz,
				lry  = lry,
			}
			-- Per-class extras (e.g. Processor queue). Merged shallow.
			local extras = FeedMachines.Serialize(f)
			if type(extras) == "table" then
				for k, v in pairs(extras) do rec[k] = v end
			end
			table.insert(placements, rec)
		end
	end
	profile.Data.FeedPlacements = placements

	local feedInventory = {}
	local function captureTool(item)
		if not isFeedTool(item) then return end
		local ft = item:GetAttribute(State.Feed.Type)
		feedInventory[ft] = (feedInventory[ft] or 0) + 1
	end
	for _, item in pairs(player.Backpack:GetChildren()) do captureTool(item) end
	if player.Character then
		captureTool(player.Character:FindFirstChildWhichIsA("Tool"))
	end
	profile.Data.FeedInventory = feedInventory

	profile.Data.FoodInventory = Food.CountByType(player)
end

local function snapshotProfileState(player, plot, profile)
	if not plot or not profile then return end
	savePetsFromPlot(plot, profile)
	saveFeedState(plot, player, profile)
	profile.Data.LastSeen = os.time()
end

-- ── Pet state replication ────────────────────────────────────────────────────
-- Per-pet state is published as attributes on the pet Model. Clients subscribe
-- via GetAttributeChangedSignal and render billboards locally (see
-- src/client/ui/PetBillboards.luau). No UI is created server-side.

local function publishPetState(pet, money, xp)
	pet:SetAttribute(State.Pet.Money, money or 0)
	pet:SetAttribute(State.Pet.XP,    xp or 0)
end

-- ── Feed prompts + evolution ─────────────────────────────────────────────────

local setupPetInteractions  -- forward decl

local function onPetEvolved(plot, player, profile, newPet)
	setupPetInteractions(plot, player, profile, newPet)
end

local function tryEvolvePet(plot, pet, player, profile)
	local idx = pet:GetAttribute(State.Pet.Index)
	local petType = pet:GetAttribute(State.Pet.Type)
	local petData = profile.Data.Pets[idx]
	if not petData then return end

	local level = Balance.PetLevelFromType(petType)
	if level >= Balance.MAX_PET_LEVEL then
		petData.xp = Balance.XPToEvolve(level - 1) -- clamp
		return
	end

	local threshold = Balance.XPToEvolve(level)
	if petData.xp < threshold then return end

	local nextType = Balance.NextPetType(petType)
	if not nextType then return end

	petData.type = nextType
	petData.xp = 0
	-- money persists on evolution

	local newPet = PlotService.ReplacePetAt(plot, pet, nextType, idx, 0)
	if newPet then
		publishPetState(newPet, petData.money, 0)
		onPetEvolved(plot, player, profile, newPet)
	end
end

local function primaryPartOf(instance)
	if not instance then return nil end
	if instance:IsA("BasePart") then return instance end
	if instance:IsA("Model") then return instance.PrimaryPart end
	return nil
end

local function isPlayerNearInstance(player, instance, maxDistance)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local primary = primaryPartOf(instance)
	return root ~= nil
		and root:IsA("BasePart")
		and primary ~= nil
		and (root.Position - primary.Position).Magnitude <= maxDistance
end

local function feedPet(plot, player, profile, pet)
	if not pet or not pet:IsA("Model") or not pet:IsDescendantOf(plot) then return end
	local primary = pet.PrimaryPart
	if not primary then return end
	if player:GetAttribute("EditMode") == true then return end
	if not isPlayerNearInstance(player, pet, 12) then return end

	local idx = pet:GetAttribute(State.Pet.Index)
	local petData = profile.Data.Pets[idx]
	if not petData then return end

	local level = Balance.PetLevelFromType(pet:GetAttribute(State.Pet.Type))
	if level >= Balance.MAX_PET_LEVEL then return end

	local food = Food.FindFirstInBackpack(player)
	if not food then return end

	local foodXP = Food.XPOf(food)
	if not foodXP then return end
	food:Destroy()

	petData.xp += foodXP
	PlotService.RescalePet(pet, petData.xp)
	pet:SetAttribute(State.Pet.XP, petData.xp)

	if petData.xp >= Balance.XPToEvolve(level) then
		tryEvolvePet(plot, pet, player, profile)
	end
end

local function setupPetCollection(plot, player, profile, pet)
	local primary = pet.PrimaryPart
	if not primary then return end

	petConnections[player] = petConnections[player] or {}
	local conn = primary.Touched:Connect(function(hit)
		local character = player.Character
		if not character or not hit:IsDescendantOf(character) then return end
		local idx = pet:GetAttribute(State.Pet.Index)
		local petData = profile.Data.Pets[idx]
		if not petData then return end
		local money = petData.money or 0
		if money < 1 then return end
		profile.Data.Currency += money
		petData.money = 0
		pet:SetAttribute(State.Pet.Money, 0)
		CurrencyUpdated:FireClient(player, profile.Data.Currency)
	end)
	table.insert(petConnections[player], conn)
end

setupPetInteractions = function(plot, player, profile, pet)
	setupPetCollection(plot, player, profile, pet)
end

local function clearPetConnections(player)
	if petConnections[player] then
		for _, conn in ipairs(petConnections[player]) do conn:Disconnect() end
		petConnections[player] = nil
	end
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

-- ── Feed machine pickup ───────────────────────────────────────────────────────
-- F-hold to retrieve a placed FeedMachine back into the inventory. Refuses
-- pickup while a Processor still has items queued so they aren't silently
-- destroyed (player must drain the queue first).
--
-- Pickup prompts are gated on the owner currently holding an EditTool —
-- they're invisible during normal play and only appear in "edit mode"
-- when the player explicitly equips the tool from their inventory.

local EDIT_TOOL_NAME = "EditTool"

local function isEditTool(tool)
	return tool ~= nil and tool:IsA("Tool") and tool.Name == EDIT_TOOL_NAME
end

-- Single source of truth for "is this player in edit mode": a boolean
-- attribute on the Player instance. Every prompt that wants to react to
-- edit mode reads this attribute (and listens for changes via
-- GetAttributeChangedSignal) — no per-prompt character watchers needed.
local function watchPlayerEditMode(player)
	local function refresh()
		local char = player.Character
		local equipped = char and char:FindFirstChildWhichIsA("Tool") or nil
		player:SetAttribute("EditMode", isEditTool(equipped))
	end
	local function watchCharacter(char)
		if not char then return end
		char.ChildAdded:Connect(function(c) if c:IsA("Tool") then refresh() end end)
		char.ChildRemoved:Connect(function(c) if c:IsA("Tool") then refresh() end end)
		refresh()
	end
	watchCharacter(player.Character)
	player.CharacterAdded:Connect(watchCharacter)
	refresh()
end

local function pickupFeed(feed, plot, player)
	if not feed or not feed:IsDescendantOf(plot) then return end
	if not ((feed:IsA("BasePart") or feed:IsA("Model")) and feed:GetAttribute(State.Feed.Type)) then return end
	if player:GetAttribute("EditMode") ~= true then return end
	if not isPlayerNearInstance(player, feed, 14) then return end
	if not FeedMachines.PrePickup(feed, player) then return end

	local feedType = feed:GetAttribute(State.Feed.Type) or feed.Name
	makeFeedTool(feedType).Parent = player.Backpack
	feed:Destroy()
end

-- Always-present inventory tool that players use to enter "edit mode".
-- Re-checked every CharacterAdded so a lost or destroyed tool comes back.
local function ensureEditTool(player)
	local template = ReplicatedStorage:FindFirstChild(EDIT_TOOL_NAME)
	if not template or not template:IsA("Tool") then return end
	-- Already in inventory or equipped?
	for _, container in ipairs({ player.Backpack, player.Character }) do
		if container then
			for _, c in ipairs(container:GetChildren()) do
				if c:IsA("Tool") and c.Name == EDIT_TOOL_NAME then return end
			end
		end
	end
	template:Clone().Parent = player.Backpack
end

-- ── Player lifecycle ──────────────────────────────────────────────────────────

Players.PlayerAdded:Connect(function(player)
	-- Wire up edit-mode tracking before any prompts get created so the
	-- "EditMode" attribute is already there when prompts read it.
	watchPlayerEditMode(player)

	local plot, _ = PlotService.AssignPlot(player)
	if not plot then
		player:Kick("The server is full (all plots are taken).")
		return
	end
	player:SetAttribute(State.Player.AssignedPlotName, plot.Name)

	local spawnLocation = plot:FindFirstChild("SpawnLocation")
	if spawnLocation then player.RespawnLocation = spawnLocation end

	local profile = PlayerDataService.LoadPlayerAsync(player)
	if not profile then
		player:SetAttribute(State.Player.AssignedPlotName, nil)
		PlotService.FreePlot(player)
		return
	end

	PlotService.SpawnPetsForPlot(plot, profile.Data.Pets)
	PlotService.SpawnFeedsForPlot(plot, profile.Data.FeedPlacements)

	for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
		FeedMachines.Setup(feed, plot, player)
		local idx   = feed:GetAttribute(State.Feed.Index)
		local saved = idx and profile.Data.FeedPlacements[idx] or nil
		if saved then FeedMachines.Apply(feed, saved) end
	end

	applyOfflineEarnings(plot, profile)

	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		local idx = pet:GetAttribute(State.Pet.Index)
		local petData = profile.Data.Pets[idx]
		local money = petData and petData.money or 0
		local xp = petData and petData.xp or 0
		publishPetState(pet, money, xp)
		setupPetInteractions(plot, player, profile, pet)
	end

	startPetMoneyLoop(player, plot, profile)
	startProfileSnapshotLoop(player, plot, profile)
	CurrencyUpdated:FireClient(player, profile.Data.Currency or 0)

	local toolsRestored = false
	local function onCharacterAdded(character)
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
						makeFeedTool(feedType).Parent = player.Backpack
					end
				end
			end
		end
		ensureEditTool(player)
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

		clearPetConnections(player)
		PlotService.DestroyPets(plot)
		-- Destroying the feed parts fires Destroying on each, which the
		-- FeedMachines registry relies on to tear down per-class state
		-- (and to despawn any food the machine spawned on the floor).
		PlotService.DestroyFeeds(plot)
		PlotService.FreePlot(player)
	end
	player:SetAttribute(State.Player.AssignedPlotName, nil)

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

PromptInteract.OnServerEvent:Connect(function(player, action, target)
	if type(action) ~= "string" or typeof(target) ~= "Instance" then return end
	if not Interactions.IsAction(action) then return end
	if not consumeRateLimit(promptLastFire, player, PROMPT_RATE_SECONDS) then return end
	local plot = PlotService.GetPlayerPlot(player)
	local profile = PlayerDataService.GetProfile(player)
	if not plot or not profile then return end

	withPlayerLock(promptLocks, player, function()
		if action == Interactions.Actions.PetFeed then
			feedPet(plot, player, profile, target)
		elseif action == Interactions.Actions.FeedPickup then
			pickupFeed(target, plot, player)
		elseif action == Interactions.Actions.FeedMachine then
			if target:IsDescendantOf(plot) and isPlayerNearInstance(player, target, 14) then
				FeedMachines.Interact(target, player)
			end
		elseif action == Interactions.Actions.PatchHarvest then
			if target:IsDescendantOf(plot) and isPlayerNearInstance(player, target, 14) then
				FeedMachines.HarvestPatchAnchor(target, player)
			end
		elseif action == Interactions.Actions.TreeGroundPickup then
			if target:IsDescendantOf(plot) and isPlayerNearInstance(player, target, 14) then
				FeedMachines.PickupTreeGround(target, player)
			end
		end
	end)
	snapshotProfileState(player, plot, profile)
end)

-- ── Feed placement remote ─────────────────────────────────────────────────────

PlaceFeedMachine.OnServerEvent:Connect(function(player, cframe)
	if not isValidCFrame(cframe) then return end
	if not consumeRateLimit(placeLastFire, player, PLACE_RATE_SECONDS) then return end
	local plot = PlotService.GetPlayerPlot(player)
	if not plot then return end

	withPlayerLock(placeLocks, player, function()
		local character = player.Character
		if not character then return end
		local tool = character:FindFirstChildWhichIsA("Tool")
		if not isFeedTool(tool) then return end

		local feedType = tool:GetAttribute(State.Feed.Type)

		local floor = plot:FindFirstChild("Floor")
		if not floor then return end

		local template = FeedMachines.GetTemplate(feedType)
		if not template then return end

		-- Bounds check + grid snap + rotation snap all in the floor's local
		-- frame, so machines align to the (possibly rotated) plot's axes
		-- rather than world axes.
		local localCF = floor.CFrame:ToObjectSpace(cframe)
		if math.abs(localCF.X) > floor.Size.X / 2 or
		   math.abs(localCF.Z) > floor.Size.Z / 2 then
			return
		end
		local snappedLX  = math.round(localCF.X)
		local snappedLZ  = math.round(localCF.Z)
		local _, lry, _  = localCF:ToEulerAnglesXYZ()
		local snappedLRY = math.round(lry / (math.pi / 2)) * (math.pi / 2)

		tool:Destroy()

		local feedPart = PlotService.PlaceFeed(plot, feedType, snappedLX, snappedLZ, snappedLRY)
		if not feedPart then return end

		FeedMachines.Setup(feedPart, plot, player)
		local profile = PlayerDataService.GetProfile(player)
		if profile then snapshotProfileState(player, plot, profile) end
	end)
end)
