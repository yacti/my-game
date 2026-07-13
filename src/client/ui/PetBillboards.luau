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
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
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
local BILLBOARD_ATTACHMENT_NAME = "PetBillboardAnchor"
local BILLBOARD_ATTACHMENT_REFRESH_PASSES = 4
local BILLBOARD_ATTACHMENT_Y_OFFSET = -1
local WATCHDOG_INTERVAL_SECONDS = 5

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

local function displayNameForPet(pet)
	local petId = pet:GetAttribute(State.Pet.Id)
	local definition = type(petId) == "string" and PetCatalog.GetDefinition(petId) or nil
	local visual = definition and definition.Visual
	local modelName = visual and visual.ModelName
	if type(modelName) == "string" and modelName ~= "" then
		return modelName
	end
	return pet.Name
end

local function ensureBillboardAttachment(primary)
	local attachment = primary:FindFirstChild(BILLBOARD_ATTACHMENT_NAME)
	if attachment and attachment:IsA("Attachment") then
		return attachment
	end

	attachment = Instance.new("Attachment")
	attachment.Name = BILLBOARD_ATTACHMENT_NAME
	attachment.Parent = primary
	return attachment
end

local function refreshBillboardAttachment(pet, primary, attachment)
	if not (pet.Parent and primary.Parent and attachment.Parent == primary) then
		return false
	end

	local boundsCF, boundsSize = pet:GetBoundingBox()
	attachment.Position = primary.CFrame:PointToObjectSpace(
		boundsCF.Position + Vector3.new(0, boundsSize.Y / 2 + BILLBOARD_ATTACHMENT_Y_OFFSET, 0)
	)
	return true
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

	local record = {
		attachmentRefreshToken = 0,
	}
	attached[pet] = record

	local billboard = activeTemplates.Stats:Clone()
	local attachment = ensureBillboardAttachment(primary)
	refreshBillboardAttachment(pet, primary, attachment)
	billboard.Adornee = attachment
	UiEffects.BindBillboardPop(billboard)
	billboard.Parent = primary
	UiEffects.BindBillboardDistancePop(billboard)
	local stats = billboard:FindFirstChild("Stats")
	local xpBar = billboard:FindFirstChild("XP")
	local fill = xpBar and xpBar:FindFirstChild("Fill")
	local xpCountLabel = descendant(xpBar, "XPCount", "TextLabel")
	local moneyLabel = descendant(stats, "Money", "TextLabel")
	local moneyRateLabel = descendant(stats, "MoneyRateLabel", "TextLabel")
	local nameLabel = descendant(stats, "NameLabel", "TextLabel")
	local nicknameLabel = descendant(stats, "NicknameLabel", "TextLabel")
	local baseNameColor = nameLabel and nameLabel.TextColor3
	local baseNicknameColor = nicknameLabel and nicknameLabel.TextColor3
	local rarityConnection

	-- Authored transparencies captured from the fresh clone, so the watchdog
	-- can detect and heal labels that some outside effect left invisible.
	local labelBaselines = {}
	local function captureBaseline(label)
		if not label then return end
		local stroke = label:FindFirstChildOfClass("UIStroke")
		labelBaselines[label] = {
			textTransparency = label.TextTransparency,
			stroke = stroke,
			strokeTransparency = stroke and stroke.Transparency or nil,
		}
	end
	captureBaseline(nameLabel)
	captureBaseline(nicknameLabel)
	captureBaseline(moneyLabel)
	captureBaseline(moneyRateLabel)
	captureBaseline(xpCountLabel)

	local function disconnectRarity()
		if rarityConnection then
			rarityConnection:Disconnect()
			rarityConnection = nil
		end
	end

	local function applyNameColor(rarity)
		if not nameLabel then return end
		nameLabel.TextColor3 = Rarities.TextColorFor(rarity, os.clock()) or Rarities.TextColorFor(Rarities.Common) or baseNameColor
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

	local function refreshAttachmentForSizeChange()
		refreshBillboardAttachment(pet, primary, attachment)
		record.attachmentRefreshToken += 1
		local token = record.attachmentRefreshToken
		task.spawn(function()
			for _ = 1, BILLBOARD_ATTACHMENT_REFRESH_PASSES do
				RunService.Heartbeat:Wait()
				if record.attachmentRefreshToken ~= token then
					return
				end
				if not refreshBillboardAttachment(pet, primary, attachment) then
					return
				end
			end
		end)
	end

	local function renderXPProgress()
		local xp    = pet:GetAttribute(State.Pet.XP)    or 0
		local maxXP = pet:GetAttribute(State.Pet.MaxXP)
		if fill then fill.Size = UDim2.new(Balance.XPProgress(xp, maxXP), 0, 1, 0) end
		if xpCountLabel then
			xpCountLabel.Text = NumberFormatter.XP(xp, "") .. "/" .. NumberFormatter.XP(maxXP, " xp")
		end
	end

	local function renderXPBar()
		renderXPProgress()
		local maxXP = pet:GetAttribute(State.Pet.MaxXP)
		if xpBar and xpBar:IsA("GuiObject") then
			xpBar.Visible = type(maxXP) == "number" and maxXP > 0
		end
	end

	local function renderMoney()
		local money = pet:GetAttribute(State.Pet.Money) or 0
		if moneyLabel then moneyLabel.Text = NumberFormatter.Currency(money) end
	end

	local function renderMoneyRate()
		local moneyRate = (pet:GetAttribute(State.Pet.MoneyRate) or 0) * petCashMultiplier()
		if moneyRateLabel then moneyRateLabel.Text = NumberFormatter.CurrencyRate(moneyRate) end
	end

	local function renderIdentity()
		local nickname = pet:GetAttribute(State.Pet.Nickname)
		local nicknameColor = pet:GetAttribute(State.Pet.NicknameColor)

		if nameLabel then nameLabel.Text = displayNameForPet(pet) end
		if nicknameLabel then
			nicknameLabel.Text = type(nickname) == "string" and ('"' .. nickname .. '"') or ""
			nicknameLabel.TextColor3 = typeof(nicknameColor) == "Color3" and nicknameColor or baseNicknameColor
		end
	end

	-- Sub-renders are isolated so one failure cannot silently skip the rest:
	-- for an idle pet this initial pass is the only guaranteed write, and a
	-- skipped renderIdentity would leave stale labels with no signal to heal.
	local function render()
		refreshAttachmentForSizeChange()
		RuntimeGuard.Run("PetBillboards.RenderMoney", renderMoney)
		RuntimeGuard.Run("PetBillboards.RenderMoneyRate", renderMoneyRate)
		RuntimeGuard.Run("PetBillboards.RenderIdentity", renderIdentity)
		RuntimeGuard.Run("PetBillboards.RenderXPBar", renderXPBar)
	end
	record.render = render
	record.lastMoney = pet:GetAttribute(State.Pet.Money) or 0

	-- Periodic self-heal: if a label drifted from its authored visibility or
	-- the name no longer matches the pet, restore it and log what drifted so
	-- field reports of missing billboard text carry the root cause.
	local function heal()
		if not (pet.Parent and billboard.Parent) then return end
		if pet:GetAttribute(State.Pet.EvolutionPaused) == true then return end

		local drift = nil
		if nameLabel then
			local expectedName = displayNameForPet(pet)
			if nameLabel.Text ~= expectedName then
				drift = string.format("NameLabel.Text %q ~= %q", nameLabel.Text, expectedName)
			end
		end
		for label, baseline in pairs(labelBaselines) do
			if label.Parent then
				if math.abs(label.TextTransparency - baseline.textTransparency) > 0.05 then
					drift = drift or string.format("%s.TextTransparency %.2f ~= %.2f",
						label.Name, label.TextTransparency, baseline.textTransparency)
					label.TextTransparency = baseline.textTransparency
				end
				local stroke = baseline.stroke
				if stroke and stroke.Parent and baseline.strokeTransparency
					and math.abs(stroke.Transparency - baseline.strokeTransparency) > 0.05 then
					drift = drift or string.format("%s.UIStroke.Transparency %.2f ~= %.2f",
						label.Name, stroke.Transparency, baseline.strokeTransparency)
					stroke.Transparency = baseline.strokeTransparency
				end
				-- Engine zero-size layout bug (see UiEffects header): a label
				-- whose TextBounds is stuck at 0/NaN has text set but draws no
				-- glyphs. Rewriting the text forces a fresh layout. Skip tiny
				-- AbsoluteSize so a distance-parked billboard is not a false
				-- positive.
				if label.Visible and label.Text ~= "" and label.AbsoluteSize.Y >= 2 then
					local bounds = label.TextBounds
					if bounds.X ~= bounds.X or bounds.Y ~= bounds.Y or bounds.X <= 0 or bounds.Y <= 0 then
						drift = drift or string.format("%s.TextBounds degenerate (%s)",
							label.Name, tostring(bounds))
						local text = label.Text
						label.Text = ""
						label.Text = text
					end
				end
			end
		end

		if drift then
			render()
			refreshNameColor()
			if not record.healWarned then
				record.healWarned = true
				warn("[PetBillboards] Healed billboard label drift on " .. pet:GetFullName() .. ": " .. drift)
			end
		end
	end
	record.heal = heal

	local function handleMoneyChanged()
		local previousMoney = tonumber(record.lastMoney) or 0
		local currentMoney = tonumber(pet:GetAttribute(State.Pet.Money)) or 0
		record.lastMoney = currentMoney
		if previousMoney >= 1 and currentMoney <= 0 and isOwnPet(pet) then
			SoundEffects.PlayVaried(SoundEffects.Names.MoneyCollected)
		end
		renderMoney()
	end

	render()
	refreshNameColor()
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.XP), "PetBillboards.XPChanged", function()
		refreshAttachmentForSizeChange()
		renderXPProgress()
	end)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.MaxXP), "PetBillboards.MaxXPChanged", render)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.Money), "PetBillboards.MoneyChanged", handleMoneyChanged)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.MoneyRate), "PetBillboards.MoneyRateChanged", render)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.Id), "PetBillboards.IdChanged", render)
	RuntimeGuard.Connect(pet:GetPropertyChangedSignal("Name"), "PetBillboards.NameChanged", renderIdentity)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.Nickname), "PetBillboards.NicknameChanged", render)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.NicknameColor), "PetBillboards.NicknameColorChanged", render)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.Rarity), "PetBillboards.RarityChanged", function()
		render()
		refreshNameColor()
	end)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.EvolutionSeq), "PetBillboards.EvolutionSeqChanged", function()
		render()
		refreshNameColor()
	end)

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

local function startWatchdog()
	local elapsed = 0
	RuntimeGuard.Connect(RunService.Heartbeat, "PetBillboards.Watchdog", function(dt)
		elapsed += dt
		if elapsed < WATCHDOG_INTERVAL_SECONDS then return end
		elapsed = 0
		for _, record in pairs(attached) do
			if type(record) == "table" and type(record.heal) == "function" then
				record.heal()
			end
		end
	end)
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
	startWatchdog()
end

return PetBillboards
