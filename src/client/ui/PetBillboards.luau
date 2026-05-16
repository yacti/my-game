-- Renders money + XP billboards over each pet on the local client.
-- Server owns the state (writes XP/Money as attributes on the pet Model);
-- this module only reads attributes and mutates cloned BillboardGui templates
-- parented locally under the pet's PrimaryPart, so billboards are per-viewer
-- and incur no replication traffic.

local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared:WaitForChild("Balance"))
local State   = require(Shared:WaitForChild("State"))

local UIFolder      = ReplicatedStorage:WaitForChild("UI")
local MoneyTemplate = UIFolder:WaitForChild("PetMoneyBillboard")
local XPTemplate    = UIFolder:WaitForChild("PetXPBillboard")

local PetBillboards = {}
local attached = {}

local function formatMoney(amount)
	return "$" .. math.floor(amount or 0)
end

local function attach(pet)
	if attached[pet] then return end

	local primary = pet.PrimaryPart
	if not primary then
		-- Wait once for the server to finish replicating PrimaryPart.
		pet:GetPropertyChangedSignal("PrimaryPart"):Once(function()
			if pet.PrimaryPart and not attached[pet] then attach(pet) end
		end)
		return
	end

	attached[pet] = true

	local moneyBB = MoneyTemplate:Clone()
	moneyBB.Parent = primary
	local moneyLbl = moneyBB:FindFirstChild("MoneyLabel")

	local xpBB = XPTemplate:Clone()
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
	pet:GetAttributeChangedSignal(State.Pet.XP):Connect(render)
	pet:GetAttributeChangedSignal(State.Pet.MaxXP):Connect(render)
	pet:GetAttributeChangedSignal(State.Pet.Money):Connect(render)
	pet:GetAttributeChangedSignal(State.Pet.Id):Connect(render)

	pet.Destroying:Connect(function()
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
	plot.ChildAdded:Connect(function(obj)
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
			obj.ChildAdded:Connect(watchPlot)
		end
	end
	for _, obj in ipairs(Workspace:GetChildren()) do onWsChild(obj) end
	Workspace.ChildAdded:Connect(onWsChild)
end

function PetBillboards.start()
	watchWorkspace()
end

return PetBillboards
