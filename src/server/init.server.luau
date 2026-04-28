print("[Server] v9 loaded — TimedNew growth chain + classed feed machines")

local Players             = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")

local Server            = ServerScriptService:WaitForChild("Server")
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService       = require(Server:WaitForChild("PlotService"))
local FeedMachines      = require(Server:WaitForChild("feedMachines"))

local Shared   = ReplicatedStorage:WaitForChild("Shared")
local Balance  = require(Shared:WaitForChild("Balance"))
local Remotes  = require(Shared:WaitForChild("Remotes"))
local State    = require(Shared:WaitForChild("State"))
local Food     = require(Shared:WaitForChild("Food"))

local CurrencyUpdated  = Remotes.get("CurrencyUpdated")
local PlaceFeedMachine = Remotes.get("PlaceFeedMachine")

local petConnections = {}

-- ── Tool factories ────────────────────────────────────────────────────────────

local function makeFeedTool(feedType, level)
	local tool = ReplicatedStorage:WaitForChild("FeedMachineTool"):Clone()
	tool.Name = feedType
	tool:SetAttribute(State.Feed.Type, feedType)
	if level then tool:SetAttribute("Level", level) end
	return tool
end

local function isFeedTool(item)
	return item and item:IsA("Tool") and item:GetAttribute(State.Feed.Type) ~= nil
end

-- ── Pet state save ────────────────────────────────────────────────────────────

-- Rebuild profile.Data.Pets from the current plot state (source of truth is the
-- spawned Models and their attributes). Preserves xp/money from the existing
-- profile entry when possible; falls back to 0.
local function savePetsFromPlot(plot, profile)
	local saved = {}
	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		local idx = pet:GetAttribute(State.Pet.Index)
		if idx then
			local existing = profile.Data.Pets and profile.Data.Pets[idx] or nil
			saved[idx] = {
				type  = pet:GetAttribute(State.Pet.Type) or (existing and existing.type) or "Pet1",
				xp    = existing and existing.xp or 0,
				money = existing and existing.money or 0,
			}
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
			-- GetPivot works uniformly for BasePart (= CFrame) and Model
			-- (= pivot), so the same record shape covers both template kinds.
			local pivot   = f:GetPivot()
			local _, ry, _ = pivot:ToEulerAnglesXYZ()
			local rec = {
				type = f:GetAttribute(State.Feed.Type) or "Timed1",
				offX = pivot.Position.X - floor.Position.X,
				offZ = pivot.Position.Z - floor.Position.Z,
				rotY = ry,
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

	-- Per-tool Level is preserved so picked-up upgraded machines come back
	-- at their current level on next session.
	local feedInventory = {}
	local function captureTool(item)
		if not isFeedTool(item) then return end
		local ft = item:GetAttribute(State.Feed.Type)
		local lv = tonumber(item:GetAttribute("Level")) or 1
		local entry = feedInventory[ft]
		if not entry then
			entry = { levels = {} }
			feedInventory[ft] = entry
		end
		table.insert(entry.levels, lv)
	end
	for _, item in pairs(player.Backpack:GetChildren()) do captureTool(item) end
	if player.Character then
		captureTool(player.Character:FindFirstChildWhichIsA("Tool"))
	end
	profile.Data.FeedInventory = feedInventory

	profile.Data.FoodInventory = Food.CountByType(player)
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

local function setupPetPrompt(plot, player, profile, pet)
	local primary = pet.PrimaryPart
	if not primary then return end

	local existing = primary:FindFirstChildOfClass("ProximityPrompt")
	if existing then existing:Destroy() end

	local prompt           = Instance.new("ProximityPrompt")
	prompt.ActionText      = "Feed"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration    = 0
	prompt.Enabled         = player:GetAttribute("EditMode") ~= true
	prompt.Parent          = primary

	-- Hide all non-pickup prompts while the player is in edit mode.
	local conn = player:GetAttributeChangedSignal("EditMode"):Connect(function()
		prompt.Enabled = player:GetAttribute("EditMode") ~= true
	end)
	pet.Destroying:Connect(function() conn:Disconnect() end)

	prompt.Triggered:Connect(function(triggeringPlayer)
		if triggeringPlayer ~= player then return end
		if player:GetAttribute("EditMode") == true then return end

		local food = Food.FindFirstInBackpack(player)
		if not food then return end

		local foodXP = food:GetAttribute(State.Food.XP) or 1
		food:Destroy()

		local idx = pet:GetAttribute(State.Pet.Index)
		local petData = profile.Data.Pets[idx]
		if not petData then return end

		local level = Balance.PetLevelFromType(pet:GetAttribute(State.Pet.Type))
		if level >= Balance.MAX_PET_LEVEL then
			return -- pet is maxed; ignore feed
		end

		petData.xp += foodXP
		PlotService.RescalePet(pet, petData.xp)
		pet:SetAttribute(State.Pet.XP, petData.xp)

		if petData.xp >= Balance.XPToEvolve(level) then
			tryEvolvePet(plot, pet, player, profile)
		end
	end)
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
	setupPetPrompt(plot, player, profile, pet)
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

local function setupFeedPickup(feed, plot, owner)
	-- For Models we anchor the prompt to the PrimaryPart; for Parts the
	-- prompt parents directly.
	local promptParent = feed:IsA("Model") and feed.PrimaryPart or feed
	if not promptParent then return end

	local prompt           = Instance.new("ProximityPrompt")
	prompt.ActionText      = "Pick Up"
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.HoldDuration    = 0.5
	prompt.Enabled         = owner:GetAttribute("EditMode") == true
	prompt.Parent          = promptParent

	local conn = owner:GetAttributeChangedSignal("EditMode"):Connect(function()
		prompt.Enabled = owner:GetAttribute("EditMode") == true
	end)
	feed.Destroying:Connect(function() conn:Disconnect() end)

	prompt.Triggered:Connect(function(triggeringPlayer)
		if triggeringPlayer ~= owner then return end
		if owner:GetAttribute("EditMode") ~= true then return end
		if not FeedMachines.PrePickup(feed, triggeringPlayer) then return end
		local feedType = feed:GetAttribute(State.Feed.Type) or "Timed1"
		-- Carry per-machine state (e.g. AppleTree level) onto the tool so
		-- re-placement restores it. Generic — non-leveled types just have
		-- a nil `level` extra and the attribute won't be set.
		local extras = FeedMachines.Serialize(feed)
		local level  = extras and extras.level or nil
		makeFeedTool(feedType, level).Parent = triggeringPlayer.Backpack
		feed:Destroy()
	end)
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

	local spawnLocation = plot:FindFirstChild("SpawnLocation")
	if spawnLocation then player.RespawnLocation = spawnLocation end

	local profile = PlayerDataService.LoadPlayerAsync(player)
	if not profile then
		PlotService.FreePlot(player)
		return
	end

	PlotService.SpawnPetsForPlot(plot, profile.Data.Pets)
	PlotService.SpawnFeedsForPlot(plot, profile.Data.FeedPlacements)

	for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
		setupFeedPickup(feed, plot, player)
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
			for feedType, entry in pairs(profile.Data.FeedInventory or {}) do
				if type(entry) == "table" and type(entry.levels) == "table" then
					for _, level in ipairs(entry.levels) do
						makeFeedTool(feedType, level).Parent = player.Backpack
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
			savePetsFromPlot(plot, profile)
			saveFeedState(plot, player, profile)
			profile.Data.LastSeen = os.time()
		end

		clearPetConnections(player)
		PlotService.DestroyPets(plot)
		-- Destroying the feed parts fires Destroying on each, which the
		-- FeedMachines registry relies on to tear down per-class state
		-- (and to despawn any food the machine spawned on the floor).
		PlotService.DestroyFeeds(plot)
		PlotService.FreePlot(player)
	end

	PlayerDataService.UnloadPlayer(player)
end)

game:BindToClose(function()
	for _, player in pairs(Players:GetPlayers()) do
		local plot    = PlotService.GetPlayerPlot(player)
		local profile = PlayerDataService.GetProfile(player)
		if plot and profile then
			savePetsFromPlot(plot, profile)
			saveFeedState(plot, player, profile)
			profile.Data.LastSeen = os.time()
		end
		PlayerDataService.UnloadPlayer(player)
	end

	-- Wait for any PlayerRemoving Release() calls that are still yielding on
	-- SetAsync. Without this, Studio may shut down before the write completes
	-- and we lose the save.
	local deadline = os.clock() + 25
	while PlayerDataService.ActiveProfileCount() > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end)

-- ── Feed placement remote ─────────────────────────────────────────────────────

PlaceFeedMachine.OnServerEvent:Connect(function(player, cframe)
	local plot = PlotService.GetPlayerPlot(player)
	if not plot then return end

	local character = player.Character
	if not character then return end
	local tool = character:FindFirstChildWhichIsA("Tool")
	if not isFeedTool(tool) then return end

	local feedType = tool:GetAttribute(State.Feed.Type)
	local toolLevel = tonumber(tool:GetAttribute("Level"))

	local floor = plot:FindFirstChild("Floor")
	if not floor then return end
	local pos = cframe.Position
	local fp  = floor.Position
	if math.abs(pos.X - fp.X) > floor.Size.X / 2 or
	   math.abs(pos.Z - fp.Z) > floor.Size.Z / 2 then
		return
	end

	local template = FeedMachines.GetTemplate(feedType)
	if not template then return end

	local snappedX = math.round(pos.X)
	local snappedZ = math.round(pos.Z)
	local placedY  = floor.Position.Y + floor.Size.Y / 2 + PlotService.TemplateHeight(template) / 2

	local _, ry, _  = cframe:ToEulerAnglesXYZ()
	local snappedRY = math.round(ry / (math.pi / 2)) * (math.pi / 2)

	local placeCFrame = CFrame.new(snappedX, placedY, snappedZ) * CFrame.Angles(0, snappedRY, 0)

	tool:Destroy()

	local feedPart = PlotService.PlaceFeed(plot, feedType, placeCFrame)
	if not feedPart then return end

	setupFeedPickup(feedPart, plot, player)
	FeedMachines.Setup(feedPart, plot, player)
	if toolLevel and toolLevel > 1 then
		FeedMachines.Apply(feedPart, { level = toolLevel })
	end
end)
