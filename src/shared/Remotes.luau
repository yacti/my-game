-- Single entry point for resolving RemoteEvents/RemoteFunctions so code never
-- types remote names as raw strings in more than one place.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}
local cache = {}
local folder

Remotes.Names = {
	AppleTreeEffect = "AppleTreeEffect",
	CurrencyUpdated = "CurrencyUpdated",
	PlaceFeedMachine = "PlaceFeedMachine",
}

local Definitions = {
	[Remotes.Names.AppleTreeEffect] = "RemoteEvent",
	[Remotes.Names.CurrencyUpdated] = "RemoteEvent",
	[Remotes.Names.PlaceFeedMachine] = "RemoteEvent",
}

local function getFolder()
	if folder then return folder end

	local existing = ReplicatedStorage:FindFirstChild("Remotes")
	if existing then
		assert(existing:IsA("Folder"), string.format("ReplicatedStorage.Remotes is a %s", existing.ClassName))
		folder = existing
		return folder
	end

	if RunService:IsServer() then
		local created = Instance.new("Folder")
		created.Name = "Remotes"
		created.Parent = ReplicatedStorage
		folder = created
	else
		folder = ReplicatedStorage:WaitForChild("Remotes")
	end
	return folder
end

function Remotes.get(name)
	assert(Definitions[name], string.format("Unknown remote %q", tostring(name)))

	local remote = cache[name]
	if not remote then
		remote = getFolder():WaitForChild(name)
		assert(remote.ClassName == Definitions[name], string.format(
			"%s exists but is a %s, expected %s",
			name,
			remote.ClassName,
			Definitions[name]
		))
		cache[name] = remote
	end
	return remote
end

local function ensure(name)
	assert(RunService:IsServer(), "Remotes can only be ensured on the server")

	local remote = cache[name]
	if remote then return remote end

	local existing = getFolder():FindFirstChild(name)
	if existing then
		assert(existing.ClassName == Definitions[name], string.format(
			"%s exists but is a %s, expected %s",
			name,
			existing.ClassName,
			Definitions[name]
		))
		cache[name] = existing
		return existing
	end

	local created = Instance.new(Definitions[name])
	created.Name = name
	created.Parent = getFolder()
	cache[name] = created
	return created
end

function Remotes.ensureAll()
	for name in pairs(Definitions) do
		ensure(name)
	end
end

return Remotes
