local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local PlacementGrid = {}
PlacementGrid.__index = PlacementGrid

local FLOOR_Y_OFFSET = 0.03

local EFFECTS = {
	{
		Name = "GridEffect",
		VisibleTransparency = 0.3,
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

local function syncEffectToFloor(effect, floor)
	effect.Size = floor.Size
	effect.CFrame = floor.CFrame * CFrame.new(0, FLOOR_Y_OFFSET, 0)
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
		_connections = {},
		_tweenByInstance = {},
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

function PlacementGrid:_effectForFloor(floor, config)
	local plot = floor and floor.Parent
	local effect = plot and plot:FindFirstChild(config.Name)
	return effect and effect:IsA("BasePart") and effect or nil
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

function PlacementGrid:_applyEffect(effect, floor, config, visible, animated)
	setPartInactive(effect)
	if visible and config.MatchFloor then
		syncEffectToFloor(effect, floor)
	end
	self:_setEffectTransparency(effect, config, visible, animated)
end

function PlacementGrid:_hideWorkspaceEffects()
	for _, descendant in ipairs(Workspace:GetDescendants()) do
		for _, config in ipairs(EFFECTS) do
			if descendant.Name == config.Name and descendant:IsA("BasePart") then
				self:_applyEffect(descendant, nil, config, false, false)
			end
		end
	end
end

function PlacementGrid:_setVisible(visible, animated)
	local floor = visible and self._getFloor() or self._floor

	if not floor then
		if not visible then self:_hideWorkspaceEffects() end
		return
	end

	for _, config in ipairs(EFFECTS) do
		local effect = self:_effectForFloor(floor, config)
		if effect then
			self:_applyEffect(effect, floor, config, visible, animated)
		end
	end
end

function PlacementGrid:_bindFloor(floor)
	if self._floor == floor then return end
	self:_disconnectFloor()
	self._floor = floor

	if not floor then return end
	table.insert(self._connections, floor:GetPropertyChangedSignal("Size"):Connect(function()
		if self._enabled then self:_setVisible(true) end
	end))
	table.insert(self._connections, floor:GetPropertyChangedSignal("CFrame"):Connect(function()
		if self._enabled then self:_setVisible(true) end
	end))
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
		self:_disconnectFloor()
		return
	end

	local floor = self._getFloor()
	self._enabled = true
	self:_bindFloor(floor)
	self:_setVisible(true, true)
end

function PlacementGrid:Destroy()
	self:SetEnabled(false)
end

return PlacementGrid
