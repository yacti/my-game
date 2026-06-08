local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlotGrid = require(Shared:WaitForChild("PlotGrid"))
local State = require(Shared:WaitForChild("State"))

local PlacementGrid = {}
PlacementGrid.__index = PlacementGrid

local FLOOR_Y_OFFSET = 0.03
local LOCAL_GRID_EFFECT_FOLDER = "__LocalGridEffects"
local LOCAL_GRID_EFFECT_PREFIX = "__LocalGridEffect_"

local EFFECTS = {
	{
		Name = "GridEffect",
		VisibleTransparency = 0.8,
		HiddenTransparency = 1,
		VisualVisibleTransparency = 0.6,
		MatchFloor = true,
		TweenInfo = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	},
}

local function setPartInactive(part)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
end

local function plotGridParts(plot, unlockedOnly)
	local parts = {}
	if not plot then return parts end

	for _, folderName in ipairs({ PlotGrid.Folders.Starter, PlotGrid.Folders.Unlockable }) do
		local folder = plot:FindFirstChild(folderName)
		if folder then
			for _, child in ipairs(folder:GetChildren()) do
				if child:IsA("BasePart")
					and (not unlockedOnly or child:GetAttribute(State.Grid.Unlocked) == true) then
					parts[#parts + 1] = child
				end
			end
		end
	end
	return parts
end

local function unlockedGridParts(plot)
	return plotGridParts(plot, true)
end

local function gridEffectNameForPart(gridPart)
	local x = PlotGrid.NormalizeInteger(gridPart:GetAttribute(PlotGrid.Attributes.X)) or 0
	local z = PlotGrid.NormalizeInteger(gridPart:GetAttribute(PlotGrid.Attributes.Z)) or 0
	return LOCAL_GRID_EFFECT_PREFIX .. PlotGrid.CoordKey(x, z)
end

local function cancelTween(tweenByInstance, instance)
	local tween = tweenByInstance[instance]
	if not tween then return end
	tween:Cancel()
	tweenByInstance[instance] = nil
end

function PlacementGrid.new(getFloor)
	assert(type(getFloor) == "function", "PlacementGrid.new requires a floor resolver")

	local self = setmetatable({
		_getFloor = getFloor,
		_enabled = false,
		_floor = nil,
		_effectFolder = nil,
		_effectClones = {},
		_connections = {},
		_tweenByInstance = {},
		_visible = false,
		_dirty = true,
	}, PlacementGrid)

	self:_hideWorkspaceEffects()
	return self
end

function PlacementGrid:_disconnectFloor()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self._floor = nil
end

function PlacementGrid:_destroyClones()
	for _, clone in pairs(self._effectClones) do
		cancelTween(self._tweenByInstance, clone)
		for _, descendant in ipairs(clone:GetDescendants()) do
			cancelTween(self._tweenByInstance, descendant)
		end
		clone:Destroy()
	end
	table.clear(self._effectClones)

	if self._effectFolder then
		self._effectFolder:Destroy()
		self._effectFolder = nil
	end
end

function PlacementGrid:_markDirty()
	self._dirty = true
end

function PlacementGrid:_effectForFloor(floor, config)
	local plot = floor and floor.Parent
	local effect = plot and plot:FindFirstChild(config.Name)
	return effect and effect:IsA("BasePart") and effect or nil
end

function PlacementGrid:_effectFolderForFloor(floor)
	local plot = floor and floor.Parent
	if not plot then return nil end

	local folder = self._effectFolder
	if folder and folder.Parent == plot then
		return folder
	end

	if folder then folder:Destroy() end
	folder = Instance.new("Folder")
	folder.Name = LOCAL_GRID_EFFECT_FOLDER
	folder.Parent = plot
	self._effectFolder = folder
	return folder
end

function PlacementGrid:_tweenTransparency(instance, tweenInfo, transparency)
	cancelTween(self._tweenByInstance, instance)

	local tween = TweenService:Create(instance, tweenInfo, { Transparency = transparency })
	self._tweenByInstance[instance] = tween
	tween.Completed:Connect(function()
		if self._tweenByInstance[instance] == tween then
			self._tweenByInstance[instance] = nil
		end
	end)
	tween:Play()
end

function PlacementGrid:_applyTransparency(instance, transparency, tweenInfo, forceStartTransparency)
	cancelTween(self._tweenByInstance, instance)
	if forceStartTransparency ~= nil then
		instance.Transparency = forceStartTransparency
	end

	if tweenInfo then
		self:_tweenTransparency(instance, tweenInfo, transparency)
	else
		instance.Transparency = transparency
	end
end

function PlacementGrid:_setEffectTransparency(effect, config, visible, animated)
	local partTransparency = visible and config.VisibleTransparency or config.HiddenTransparency
	local startTransparency = visible and config.HiddenTransparency or nil
	local tweenInfo = animated and config.TweenInfo or nil
	effect.LocalTransparencyModifier = 0

	self:_applyTransparency(effect, partTransparency, tweenInfo, startTransparency)

	for _, descendant in ipairs(effect:GetDescendants()) do
		if descendant:IsA("Texture") or descendant:IsA("Decal") then
			local visualTransparency = visible
				and (config.VisualVisibleTransparency or config.VisibleTransparency)
				or config.HiddenTransparency

			self:_applyTransparency(descendant, visualTransparency, tweenInfo, startTransparency)
		end
	end
end

function PlacementGrid:_syncCloneToGridPart(clone, gridPart)
	clone.Size = Vector3.new(gridPart.Size.X, clone.Size.Y, gridPart.Size.Z)
	clone.CFrame = gridPart.CFrame * CFrame.new(0, FLOOR_Y_OFFSET, 0)
end

function PlacementGrid:_createClone(template, gridPart, config)
	local folder = self:_effectFolderForFloor(self._floor)
	if not folder then return nil end

	local clone = template:Clone()
	clone.Name = gridEffectNameForPart(gridPart)
	setPartInactive(clone)
	self:_syncCloneToGridPart(clone, gridPart)
	self:_setEffectTransparency(clone, config, false, false)
	clone.Parent = folder
	return clone
end

function PlacementGrid:_syncClones(template, floor, config, animated)
	local live = {}
	for _, gridPart in ipairs(unlockedGridParts(floor.Parent)) do
		local name = gridEffectNameForPart(gridPart)
		live[name] = true

		local clone = self._effectClones[name]
		if not clone or clone.Parent == nil then
			clone = self:_createClone(template, gridPart, config)
			if clone then self._effectClones[name] = clone end
		elseif clone.Parent ~= self:_effectFolderForFloor(floor) then
			clone.Parent = self:_effectFolderForFloor(floor)
		end

		if clone then
			if self._dirty then
				self:_syncCloneToGridPart(clone, gridPart)
			end
			self:_setEffectTransparency(clone, config, true, animated)
		end
	end

	for name, clone in pairs(self._effectClones) do
		if not live[name] then
			cancelTween(self._tweenByInstance, clone)
			for _, descendant in ipairs(clone:GetDescendants()) do
				cancelTween(self._tweenByInstance, descendant)
			end
			clone:Destroy()
			self._effectClones[name] = nil
		end
	end
end

function PlacementGrid:_applyTemplateEffect(effect, config)
	setPartInactive(effect)
	self:_setEffectTransparency(effect, config, false, false)
end

function PlacementGrid:_hideWorkspaceEffects()
	for _, descendant in ipairs(Workspace:GetDescendants()) do
		for _, config in ipairs(EFFECTS) do
			if descendant.Name == config.Name and descendant:IsA("BasePart") then
				self:_applyTemplateEffect(descendant, config)
			end
		end
	end
	self:_destroyClones()
end

function PlacementGrid:_setVisible(visible, animated)
	local floor = visible and self._getFloor() or self._floor

	if not floor then
		self._visible = false
		return
	end

	if visible and self._visible and not self._dirty then
		return
	end

	for _, config in ipairs(EFFECTS) do
		local effect = self:_effectForFloor(floor, config)
		if effect then
			self:_applyTemplateEffect(effect, config)
			if visible then
				self:_syncClones(effect, floor, config, animated)
			else
				for _, clone in pairs(self._effectClones) do
					self:_setEffectTransparency(clone, config, false, animated)
				end
			end
		end
	end

	self._visible = visible
	if visible then
		self._dirty = false
	end
end

function PlacementGrid:_bindFloor(floor)
	if self._floor == floor then return end
	self:_destroyClones()
	self:_disconnectFloor()
	self._floor = floor
	self._visible = false
	self:_markDirty()

	if not floor then return end
	table.insert(self._connections, floor:GetPropertyChangedSignal("Size"):Connect(function()
		self:_markDirty()
		if self._enabled then self:_setVisible(true) end
	end))
	table.insert(self._connections, floor:GetPropertyChangedSignal("CFrame"):Connect(function()
		self:_markDirty()
		if self._enabled then self:_setVisible(true) end
	end))

	local plot = floor.Parent
	for _, gridPart in ipairs(plotGridParts(plot, false)) do
		table.insert(self._connections, gridPart:GetAttributeChangedSignal(State.Grid.Unlocked):Connect(function()
			self:_markDirty()
			if self._enabled then self:_setVisible(true) end
		end))
	end
end

function PlacementGrid:SetEnabled(enabled)
	if self._enabled == enabled then
		if enabled then
			self:_bindFloor(self._getFloor())
			self:_setVisible(true)
		end
		return
	end

	if not enabled then
		self._enabled = false
		self:_setVisible(false, true)
		return
	end

	local floor = self._getFloor()
	self._enabled = true
	self:_bindFloor(floor)
	self:_setVisible(true, true)
end

function PlacementGrid:Destroy()
	self._enabled = false
	self:_disconnectFloor()
	self:_destroyClones()
end

return PlacementGrid
