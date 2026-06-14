-- Renders pet stat billboards over each pet on the local client.
-- Server owns the state (writes XP/Money/Nickname as attributes on the pet Model);
-- this module only reads attributes and mutates cloned BillboardGui templates
-- parented locally under the pet's PrimaryPart, so billboards are per-viewer
-- and incur no replication traffic.

local Workspace         = game:GetService("Workspace")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared:WaitForChild("Balance"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local PlayerBonuses = require(Shared:WaitForChild("PlayerBonuses"))
local Rarities = require(Shared:WaitForChild("Rarities"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State   = require(Shared:WaitForChild("State"))
local BillboardGuiTemplates = require(script.Parent:WaitForChild("BillboardGuiTemplates"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local PetBillboards = {}
local attached = {}
local templates

local TEMPLATE_WAIT_SECONDS = 8

local function loadTemplates()
	if templates then return templates end
	if templates == false then return nil end

	local moneyTemplate = BillboardGuiTemplates.WaitFor("PetMoneyBillboard", TEMPLATE_WAIT_SECONDS)
	if not moneyTemplate or not moneyTemplate:IsA("BillboardGui") then
		warn("[PetBillboards] Missing " .. BillboardGuiTemplates.Path("PetMoneyBillboard") .. " BillboardGui; pet billboards disabled")
		templates = false
		return nil
	end

	templates = {
		Stats = moneyTemplate,
	}
	return templates
end

local function descendant(parent, name, className)
	if not parent then return nil end
	for _, instance in ipairs(parent:GetDescendants()) do
		if instance.Name == name and (not className or instance:IsA(className)) then
			return instance
		end
	end
	return nil
end

local function ownershipMap()
	local map = PlayerStateStore.Get(PlayerStateStore.Fields.GamePassOwnership)
	local copy = type(map) == "table" and table.clone(map) or {}
	if PlayerStateStore.Get(PlayerStateStore.Fields.VipOwned) == true then
		copy[ShopBalance.GamePassKeys.VIP] = true
	end
	return copy
end

local function petCashMultiplier()
	return PlayerBonuses.PetCashMultiplier(ownershipMap())
end

local function refreshAll()
	for pet, record in pairs(attached) do
		if pet.Parent and type(record) == "table" and type(record.render) == "function" then
			record.render()
		else
			attached[pet] = nil
		end
	end
end

local function isOwnPet(pet)
	local plot = PlotResolver.ResolveForPlayer(Players.LocalPlayer)
	return plot ~= nil and pet:IsDescendantOf(plot)
end

local function attach(pet)
	if attached[pet] then return end
	local activeTemplates = loadTemplates()
	if not activeTemplates then return end

	local primary = pet.PrimaryPart
	if not primary then
		-- Wait once for the server to finish replicating PrimaryPart.
		pet:GetPropertyChangedSignal("PrimaryPart"):Once(function()
			if pet.PrimaryPart and not attached[pet] then attach(pet) end
		end)
		return
	end

	local record = {}
	attached[pet] = record

	local billboard = activeTemplates.Stats:Clone()
	UiEffects.BindBillboardPop(billboard)
	billboard.Parent = primary
	UiEffects.BindBillboardDistancePop(billboard)
	local stats = billboard:FindFirstChild("Stats")
	local xpBar = billboard:FindFirstChild("XP")
	local fill = xpBar and xpBar:FindFirstChild("Fill")
	local moneyLabel = descendant(stats, "Money", "TextLabel")
	local moneyRateLabel = descendant(stats, "MoneyRateLabel", "TextLabel")
	local nameLabel = descendant(stats, "NameLabel", "TextLabel")
	local nicknameLabel = descendant(stats, "NicknameLabel", "TextLabel")
	local baseNameColor = nameLabel and nameLabel.TextColor3
	local baseNicknameColor = nicknameLabel and nicknameLabel.TextColor3
	local rarityConnection

	local function disconnectRarity()
		if rarityConnection then
			rarityConnection:Disconnect()
			rarityConnection = nil
		end
	end

	local function applyNameColor(rarity)
		if not nameLabel then return end
		nameLabel.TextColor3 = Rarities.ColorFor(rarity, os.clock()) or Rarities.ColorFor(Rarities.Common) or baseNameColor
	end

	local function refreshNameColor()
		disconnectRarity()

		local rarity = pet:GetAttribute(State.Pet.Rarity)
		applyNameColor(rarity)

		local definition = type(rarity) == "string" and Rarities.Get(rarity) or nil
		if definition and definition.Animated then
			rarityConnection = RuntimeGuard.Connect(RunService.RenderStepped, "PetBillboards.RarityRender", function()
				if not pet.Parent or not nameLabel or not nameLabel.Parent then
					disconnectRarity()
					return
				end
				applyNameColor(rarity)
			end)
		end
	end

	local function render()
		local xp    = pet:GetAttribute(State.Pet.XP)    or 0
		local money = pet:GetAttribute(State.Pet.Money) or 0
		local maxXP = pet:GetAttribute(State.Pet.MaxXP)
		local moneyRate = (pet:GetAttribute(State.Pet.MoneyRate) or 0) * petCashMultiplier()
		local nickname = pet:GetAttribute(State.Pet.Nickname)
		local nicknameColor = pet:GetAttribute(State.Pet.NicknameColor)

		if moneyLabel then moneyLabel.Text = NumberFormatter.Currency(money) end
		if moneyRateLabel then moneyRateLabel.Text = NumberFormatter.CurrencyRate(moneyRate) end
		if nameLabel then nameLabel.Text = pet.Name end
		if nicknameLabel then
			nicknameLabel.Text = type(nickname) == "string" and ('"' .. nickname .. '"') or ""
			nicknameLabel.TextColor3 = typeof(nicknameColor) == "Color3" and nicknameColor or baseNicknameColor
		end
		if fill then fill.Size = UDim2.new(Balance.XPProgress(xp, maxXP), 0, 1, 0) end
		if xpBar and xpBar:IsA("GuiObject") then
			xpBar.Visible = type(maxXP) == "number" and maxXP > 0
		end
	end
	record.render = render
	record.lastMoney = pet:GetAttribute(State.Pet.Money) or 0

	local function handleMoneyChanged()
		local previousMoney = tonumber(record.lastMoney) or 0
		local currentMoney = tonumber(pet:GetAttribute(State.Pet.Money)) or 0
		record.lastMoney = currentMoney
		if previousMoney >= 1 and currentMoney <= 0 and isOwnPet(pet) then
			SoundEffects.PlayVaried(SoundEffects.Names.MoneyCollected)
		end
		render()
	end

	render()
	refreshNameColor()
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.XP), "PetBillboards.XPChanged", render)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.MaxXP), "PetBillboards.MaxXPChanged", render)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.Money), "PetBillboards.MoneyChanged", handleMoneyChanged)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.MoneyRate), "PetBillboards.MoneyRateChanged", render)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.Id), "PetBillboards.IdChanged", render)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.Nickname), "PetBillboards.NicknameChanged", render)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.NicknameColor), "PetBillboards.NicknameColorChanged", render)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.Rarity), "PetBillboards.RarityChanged", refreshNameColor)

	RuntimeGuard.Connect(pet.Destroying, "PetBillboards.PetDestroying", function()
		disconnectRarity()
		attached[pet] = nil
	end)
end

local function isPet(obj)
	return obj:IsA("Model") and obj:GetAttribute(State.Pet.Index) ~= nil
end

local function watchPlot(plot)
	for _, obj in ipairs(plot:GetChildren()) do
		if isPet(obj) then attach(obj) end
	end
	RuntimeGuard.Connect(plot.ChildAdded, "PetBillboards.PlotChildAdded", function(obj)
		if isPet(obj) then attach(obj) end
	end)
end

local function isPlot(obj)
	return (obj:IsA("Model") or obj:IsA("Folder")) and obj.Name:match("^Plot%d") ~= nil
end

local function watchWorkspace()
	local function onWsChild(obj)
		if isPlot(obj) then
			watchPlot(obj)
		elseif obj.Name == "Plots" then
			for _, plot in ipairs(obj:GetChildren()) do watchPlot(plot) end
			RuntimeGuard.Connect(obj.ChildAdded, "PetBillboards.PlotsChildAdded", watchPlot)
		end
	end
	for _, obj in ipairs(Workspace:GetChildren()) do onWsChild(obj) end
	RuntimeGuard.Connect(Workspace.ChildAdded, "PetBillboards.WorkspaceChildAdded", onWsChild)
end

function PetBillboards.start()
	PlayerStateStore.Observe(PlayerStateStore.Fields.VipOwned, refreshAll)
	PlayerStateStore.Observe(PlayerStateStore.Fields.GamePassOwnership, refreshAll)
	watchWorkspace()
end

return PetBillboards
