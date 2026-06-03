-- Renders money + XP billboards over each pet on the local client.
-- Server owns the state (writes XP/Money as attributes on the pet Model);
-- this module only reads attributes and mutates cloned BillboardGui templates
-- parented locally under the pet's PrimaryPart, so billboards are per-viewer
-- and incur no replication traffic.

local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared:WaitForChild("Balance"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State   = require(Shared:WaitForChild("State"))

local PetBillboards = {}
local attached = {}
local templates

local TEMPLATE_WAIT_SECONDS = 8

local function loadTemplates()
	if templates then return templates end
	if templates == false then return nil end

	local uiFolder = ReplicatedStorage:WaitForChild("UI", TEMPLATE_WAIT_SECONDS)
	if not uiFolder then
		warn("[PetBillboards] Missing ReplicatedStorage.UI; pet billboards disabled")
		templates = false
		return nil
	end

	local moneyTemplate = uiFolder:WaitForChild("PetMoneyBillboard", TEMPLATE_WAIT_SECONDS)
	local xpTemplate = uiFolder:WaitForChild("PetXPBillboard", TEMPLATE_WAIT_SECONDS)
	if not moneyTemplate or not moneyTemplate:IsA("BillboardGui") then
		warn("[PetBillboards] Missing UI.PetMoneyBillboard BillboardGui; pet money billboards disabled")
		templates = false
		return nil
	end
	if not xpTemplate or not xpTemplate:IsA("BillboardGui") then
		warn("[PetBillboards] Missing UI.PetXPBillboard BillboardGui; pet XP billboards disabled")
		templates = false
		return nil
	end

	templates = {
		Money = moneyTemplate,
		XP = xpTemplate,
	}
	return templates
end

local function formatMoney(amount)
	return "$" .. math.floor(amount or 0)
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

	attached[pet] = true

	local moneyBB = activeTemplates.Money:Clone()
	moneyBB.Parent = primary
	local moneyLbl = moneyBB:FindFirstChild("MoneyLabel")

	local xpBB = activeTemplates.XP:Clone()
	xpBB.Parent = primary
	local bg   = xpBB:FindFirstChild("Background")
	local fill = bg and bg:FindFirstChild("Fill")

	local function render()
		local xp    = pet:GetAttribute(State.Pet.XP)    or 0
		local money = pet:GetAttribute(State.Pet.Money) or 0
		local maxXP = pet:GetAttribute(State.Pet.MaxXP)
		if moneyLbl then moneyLbl.Text = formatMoney(money) end
		if fill then fill.Size = UDim2.new(Balance.XPProgress(xp, maxXP), 0, 1, 0) end
		xpBB.Enabled = type(maxXP) == "number" and maxXP > 0
	end

	render()
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.XP), "PetBillboards.XPChanged", render)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.MaxXP), "PetBillboards.MaxXPChanged", render)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.Money), "PetBillboards.MoneyChanged", render)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.Id), "PetBillboards.IdChanged", render)

	RuntimeGuard.Connect(pet.Destroying, "PetBillboards.PetDestroying", function()
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
	watchWorkspace()
end

return PetBillboards
