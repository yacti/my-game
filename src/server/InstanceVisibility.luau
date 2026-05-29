local InstanceVisibility = {}

local partStates = setmetatable({}, { __mode = "k" })
local visualStates = setmetatable({}, { __mode = "k" })
local enabledStates = setmetatable({}, { __mode = "k" })

local function isRuntimeHiddenPart(part)
	return part.Transparency >= 1
		and part.CanCollide == false
		and part.CanTouch == false
		and part.CanQuery == false
end

local function rememberPartState(part, options)
	local state = partStates[part]
	if state then return state end

	if options and options.RuntimeHiddenAsVisible and isRuntimeHiddenPart(part) then
		local collides = true
		if options.RuntimeHiddenCanCollide then
			collides = options.RuntimeHiddenCanCollide(part) == true
		end
		state = {
			Transparency = 0,
			CanCollide = collides,
			CanTouch = collides,
			CanQuery = collides,
			CastShadow = true,
		}
	else
		state = {
			Transparency = part.Transparency,
			CanCollide = part.CanCollide,
			CanTouch = part.CanTouch,
			CanQuery = part.CanQuery,
			CastShadow = part.CastShadow,
		}
	end
	partStates[part] = state
	return state
end

local function rememberVisualState(instance, options)
	local state = visualStates[instance]
	if state then return state end

	state = {
		Transparency = options and options.RuntimeHiddenVisualAsVisible and instance.Transparency >= 1 and 0 or instance.Transparency,
	}
	visualStates[instance] = state
	return state
end

local function rememberEnabledState(instance)
	local state = enabledStates[instance]
	if state ~= nil then return state end

	state = instance.Enabled
	enabledStates[instance] = state
	return state
end

function InstanceVisibility.SetActive(instance, active, options)
	if instance:IsA("BasePart") then
		local state = rememberPartState(instance, options)
		if active then
			instance.Transparency = state.Transparency
			instance.CanCollide = state.CanCollide
			instance.CanTouch = state.CanTouch
			instance.CanQuery = state.CanQuery
			instance.CastShadow = state.CastShadow
		else
			instance.Transparency = 1
			instance.CanCollide = false
			instance.CanTouch = false
			instance.CanQuery = false
			instance.CastShadow = false
		end
	elseif instance:IsA("Decal") or instance:IsA("Texture") then
		local state = rememberVisualState(instance, options)
		instance.Transparency = active and state.Transparency or 1
	elseif instance:IsA("LayerCollector") or instance:IsA("ProximityPrompt") or instance:IsA("ParticleEmitter")
		or instance:IsA("Beam") or instance:IsA("Trail") then
		local state = rememberEnabledState(instance)
		instance.Enabled = active and state or false
	end
end

function InstanceVisibility.SetTreeActive(instance, active, options)
	InstanceVisibility.SetActive(instance, active, options)
	for _, descendant in ipairs(instance:GetDescendants()) do
		InstanceVisibility.SetActive(descendant, active, options)
	end
end

function InstanceVisibility.Forget(instance)
	partStates[instance] = nil
	visualStates[instance] = nil
	enabledStates[instance] = nil
end

function InstanceVisibility.ForgetTree(instance)
	InstanceVisibility.Forget(instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		InstanceVisibility.Forget(descendant)
	end
end

return InstanceVisibility
