print("[Server] v7 loaded — pet XP + evolution system")

local Players             = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace           = game:GetService("Workspace")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")

local Server            = ServerScriptService:WaitForChild("Server")
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService       = require(Server:WaitForChild("PlotService"))
local Balance           = require(ReplicatedStorage.Shared:WaitForChild("Balance"))

local Remotes          = ReplicatedStorage:WaitForChild("Remotes")
local CurrencyUpdated  = Remotes:WaitForChild("CurrencyUpdated")
local PlaceFeedMachine = Remotes:WaitForChild("PlaceFeedMachine")

local FoodFolder = ReplicatedStorage:WaitForChild("Food")
local AppleTemplate = FoodFolder:WaitForChild("Apple")

local UIFolder             = ReplicatedStorage:WaitForChild("UI")
local MoneyBillboardTemplate = UIFolder:WaitForChild("PetMoneyBillboard")
local XPBillboardTemplate    = UIFolder:WaitForChild("PetXPBillboard")

local MAX_APPLES_PER_FEED = 5

local petConnections = {}

-- ── Tool factories ────────────────────────────────────────────────────────────

local function makeAppleTool()
	local tool              = Instance.new("Tool")
	tool.Name               = "Apple"
	tool.RequiresHandle     = true

	local handle            = AppleTemplate:Clone()
	handle.Name             = "Handle"
	handle.Anchored         = false
	handle.CanCollide       = true
	handle.Massless         = true
	handle.Parent           = tool

	local xp = AppleTemplate:GetAttribute("XP") or 1
	tool:SetAttribute("XP", xp)
	return tool
end

local function makeFeedTool(feedType)
	local tool = ReplicatedStorage:WaitForChild("FeedMachineTool"):Clone()
	tool.Name = "FeedMachine"
	if feedType then tool:SetAttribute("FeedType", feedType) end
	return tool
end

-- ── Apple helpers ─────────────────────────────────────────────────────────────

local function countPlayerApples(player)
	local count = 0
	for _, item in pairs(player.Backpack:GetChildren()) do
		if item.Name == "Apple" then count += 1 end
	end
	if player.Character then
		local equipped = player.Character:FindFirstChildWhichIsA("Tool")
		if equipped and equipped.Name == "Apple" then count += 1 end
	end
	return count
end

local function countPlotApples(plotName)
	local count = 0
	for _, obj in pairs(Workspace:GetChildren()) do
		if obj:IsA("Tool") and obj.Name == "Apple" and obj:GetAttribute("Plot") == plotName then
			count += 1
		end
	end
	return count
end

local function clearPlotApples(plotName)
	for _, obj in pairs(Workspace:GetChildren()) do
		if obj:IsA("Tool") and obj.Name == "Apple" and obj:GetAttribute("Plot") == plotName then
			obj:Destroy()
		end
	end
end

-- ── Pet state save ────────────────────────────────────────────────────────────

-- Rebuild profile.Data.Pets from the current plot state (source of truth is the
-- spawned Models and their attributes). Preserves xp/money from the existing
-- profile entry when possible; falls back to 0.
local function savePetsFromPlot(plot, profile)
	local saved = {}
	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		local idx = pet:GetAttribute("PetIndex")
		if idx then
			local existing = profile.Data.Pets and profile.Data.Pets[idx] or nil
			saved[idx] = {
				type  = pet:GetAttribute("PetType") or (existing and existing.type) or "Pet1",
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
			local _, ry, _ = f.CFrame:ToEulerAnglesXYZ()
			table.insert(placements, {
				type = f:GetAttribute("FeedType") or "Feed1",
				offX = f.Position.X - floor.Position.X,
				offZ = f.Position.Z - floor.Position.Z,
				rotY = ry,
			})
		end
	end
	profile.Data.FeedPlacements = placements

	local inventory = {}
	for _, item in pairs(player.Backpack:GetChildren()) do
		if item.Name == "FeedMachine" then
			local ft = item:GetAttribute("FeedType") or "Feed1"
			inventory[ft] = (inventory[ft] or 0) + 1
		end
	end
	if player.Character then
		local eq = player.Character:FindFirstChildWhichIsA("Tool")
		if eq and eq.Name == "FeedMachine" then
			local ft = eq:GetAttribute("FeedType") or "Feed1"
			inventory[ft] = (inventory[ft] or 0) + 1
		end
	end
	profile.Data.FeedInventory = inventory
end

-- ── Billboards: money (above) + XP (below) ───────────────────────────────────

local function formatMoney(amount)
	return "$" .. math.floor(amount)
end

local function setupPetBillboards(pet, money, xp)
	local primary = pet.PrimaryPart
	if not primary then return end

	local existingMoney = primary:FindFirstChild("PetMoneyBillboard")
	if existingMoney then existingMoney:Destroy() end
	local existingXP = primary:FindFirstChild("PetXPBillboard")
	if existingXP then existingXP:Destroy() end

	local moneyBB = MoneyBillboardTemplate:Clone()
	moneyBB.Parent = primary
	local moneyLbl = moneyBB:FindFirstChild("MoneyLabel")
	if moneyLbl then moneyLbl.Text = formatMoney(money) end

	local xpBB = XPBillboardTemplate:Clone()
	xpBB.Parent = primary
	local fill = xpBB:FindFirstChild("Background") and xpBB.Background:FindFirstChild("Fill")
	local level = Balance.PetLevelFromType(pet:GetAttribute("PetType"))
	if fill then
		fill.Size = UDim2.new(Balance.XPProgress(xp or 0, level), 0, 1, 0)
	end
	xpBB.Enabled = level < Balance.MAX_PET_LEVEL
end

local function updateMoneyBillboard(pet, amount)
	local primary = pet.PrimaryPart
	if not primary then return end
	local bb = primary:FindFirstChild("PetMoneyBillboard")
	local lbl = bb and bb:FindFirstChild("MoneyLabel")
	if lbl then lbl.Text = formatMoney(amount) end
end

local function updateXPBillboard(pet, xp)
	local primary = pet.PrimaryPart
	if not primary then return end
	local bb = primary:FindFirstChild("PetXPBillboard")
	if not bb then return end
	local fill = bb:FindFirstChild("Background") and bb.Background:FindFirstChild("Fill")
	if not fill then return end
	local level = Balance.PetLevelFromType(pet:GetAttribute("PetType"))
	fill.Size = UDim2.new(Balance.XPProgress(xp or 0, level), 0, 1, 0)
	bb.Enabled = level < Balance.MAX_PET_LEVEL
end

-- ── Feed prompts + evolution ─────────────────────────────────────────────────

local setupPetInteractions  -- forward decl

local function onPetEvolved(plot, player, profile, newPet)
	setupPetInteractions(plot, player, profile, newPet)
end

local function tryEvolvePet(plot, pet, player, profile)
	local idx = pet:GetAttribute("PetIndex")
	local petType = pet:GetAttribute("PetType")
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
		setupPetBillboards(newPet, petData.money, 0)
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
	prompt.Parent          = primary

	prompt.Triggered:Connect(function(triggeringPlayer)
		if triggeringPlayer ~= player then return end

		local apple = player.Backpack:FindFirstChild("Apple")
		if not apple and player.Character then
			local equipped = player.Character:FindFirstChildWhichIsA("Tool")
			if equipped and equipped.Name == "Apple" then apple = equipped end
		end
		if not apple then return end

		local appleXP = apple:GetAttribute("XP") or 1
		apple:Destroy()

		local idx = pet:GetAttribute("PetIndex")
		local petData = profile.Data.Pets[idx]
		if not petData then return end

		local level = Balance.PetLevelFromType(pet:GetAttribute("PetType"))
		if level >= Balance.MAX_PET_LEVEL then
			return -- pet is maxed; ignore feed
		end

		petData.xp += appleXP
		PlotService.RescalePet(pet, petData.xp)
		updateXPBillboard(pet, petData.xp)

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
		local idx = pet:GetAttribute("PetIndex")
		local petData = profile.Data.Pets[idx]
		if not petData then return end
		local money = petData.money or 0
		if money < 1 then return end
		profile.Data.Currency += money
		petData.money = 0
		updateMoneyBillboard(pet, 0)
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
		local idx = pet:GetAttribute("PetIndex")
		local petData = profile.Data.Pets[idx]
		if petData then
			local rate = pet:GetAttribute("MoneyRate") or 1
			petData.money = (petData.money or 0) + rate * elapsed
		end
	end
end

local function startPetMoneyLoop(player, plot, profile)
	task.spawn(function()
		while PlotService.GetPlayerPlot(player) == plot do
			task.wait(1)
			for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
				local idx = pet:GetAttribute("PetIndex")
				local petData = profile.Data.Pets[idx]
				if petData then
					local rate = pet:GetAttribute("MoneyRate") or 1
					petData.money = (petData.money or 0) + rate
					updateMoneyBillboard(pet, petData.money)
				end
			end
		end
	end)
end

-- ── Feed machine pickup ───────────────────────────────────────────────────────

local function setupFeedPickup(feedPart, plot, owner)
	local prompt           = Instance.new("ProximityPrompt")
	prompt.ActionText      = "Pick Up"
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.HoldDuration    = 0.5
	prompt.Parent          = feedPart

	prompt.Triggered:Connect(function(triggeringPlayer)
		if triggeringPlayer ~= owner then return end
		local feedType = feedPart:GetAttribute("FeedType") or "Feed1"
		makeFeedTool(feedType).Parent = triggeringPlayer.Backpack
		feedPart:Destroy()
	end)
end

-- ── Apple spawning loop ───────────────────────────────────────────────────────

task.spawn(function()
	while true do
		task.wait(2)
		for _, plot in pairs(PlotService.GetPlots()) do
			local feeds = PlotService.GetSortedFeeds(plot)
			if #feeds == 0 then continue end
			local cap = #feeds * MAX_APPLES_PER_FEED
			if countPlotApples(plot.Name) >= cap then continue end

			local feed = feeds[math.random(1, #feeds)]
			local tool = makeAppleTool()
			tool:SetAttribute("Plot", plot.Name)
			tool.Parent = Workspace
			tool.Handle.CFrame = CFrame.new(feed.Position + Vector3.new(0, feed.Size.Y / 2 + 1, 0))
		end
	end
end)

-- ── Player lifecycle ──────────────────────────────────────────────────────────

Players.PlayerAdded:Connect(function(player)
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
	end

	applyOfflineEarnings(plot, profile)

	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		local idx = pet:GetAttribute("PetIndex")
		local petData = profile.Data.Pets[idx]
		local money = petData and petData.money or 0
		local xp = petData and petData.xp or 0
		setupPetBillboards(pet, money, xp)
		setupPetInteractions(plot, player, profile, pet)
	end

	startPetMoneyLoop(player, plot, profile)
	CurrencyUpdated:FireClient(player, profile.Data.Currency or 0)

	local toolsRestored = false
	local function onCharacterAdded(character)
		if not toolsRestored then
			toolsRestored = true
			task.wait(0.5)
			for _ = 1, profile.Data.Apples do
				makeAppleTool().Parent = player.Backpack
			end
			for feedType, count in pairs(profile.Data.FeedInventory or {}) do
				for _ = 1, count do
					makeFeedTool(feedType).Parent = player.Backpack
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
			profile.Data.Apples   = countPlayerApples(player)
			savePetsFromPlot(plot, profile)
			saveFeedState(plot, player, profile)
			profile.Data.LastSeen = os.time()
		end

		clearPetConnections(player)
		PlotService.DestroyPets(plot)
		PlotService.DestroyFeeds(plot)
		clearPlotApples(plot.Name)
		PlotService.FreePlot(player)
	end

	PlayerDataService.UnloadPlayer(player)
end)

game:BindToClose(function()
	for _, player in pairs(Players:GetPlayers()) do
		local plot    = PlotService.GetPlayerPlot(player)
		local profile = PlayerDataService.GetProfile(player)
		if plot and profile then
			profile.Data.Apples   = countPlayerApples(player)
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
	local tool = character:FindFirstChild("FeedMachine")
	if not tool then return end

	local feedType = tool:GetAttribute("FeedType") or "Feed1"

	local floor = plot:FindFirstChild("Floor")
	if not floor then return end
	local pos = cframe.Position
	local fp  = floor.Position
	if math.abs(pos.X - fp.X) > floor.Size.X / 2 or
	   math.abs(pos.Z - fp.Z) > floor.Size.Z / 2 then
		return
	end

	local template = ReplicatedStorage:WaitForChild("FeedMachines"):WaitForChild(feedType)
	local snappedX = math.round(pos.X)
	local snappedZ = math.round(pos.Z)
	local placedY  = floor.Position.Y + floor.Size.Y / 2 + template.Size.Y / 2

	local _, ry, _  = cframe:ToEulerAnglesXYZ()
	local snappedRY = math.round(ry / (math.pi / 2)) * (math.pi / 2)

	local placeCFrame = CFrame.new(snappedX, placedY, snappedZ) * CFrame.Angles(0, snappedRY, 0)

	tool:Destroy()

	local feedPart    = template:Clone()
	feedPart.Name     = feedType
	feedPart.Anchored = true
	feedPart.CFrame   = placeCFrame
	feedPart:SetAttribute("FeedType", feedType)

	local maxIndex = 0
	for _, f in ipairs(PlotService.GetSortedFeeds(plot)) do
		local idx = f:GetAttribute("FeedIndex") or 0
		if idx > maxIndex then maxIndex = idx end
	end
	feedPart:SetAttribute("FeedIndex", maxIndex + 1)
	feedPart.Parent = plot

	setupFeedPickup(feedPart, plot, player)
end)
