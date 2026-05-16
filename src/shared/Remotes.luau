-- Single entry point for resolving RemoteEvents/RemoteFunctions so code never
-- types remote names as raw strings in more than one place. Remote instances
-- are declared in default.project.json and synced by Rojo; this module only
-- validates and resolves them so Studio-only duplicates fail loudly.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}
local cache = {}
local folder

Remotes.Names = {
	ProcessorDepositEffect = "ProcessorDepositEffect",
	TreeClickerEffect = "TreeClickerEffect",
	CurrencyUpdated = "CurrencyUpdated",
	PlaceFeedMachine = "PlaceFeedMachine",
	PlaceFeedMachineResult = "PlaceFeedMachineResult",
	PromptInteract = "PromptInteract",
}

local Definitions = {
	[Remotes.Names.ProcessorDepositEffect] = "RemoteEvent",
	[Remotes.Names.TreeClickerEffect] = "RemoteEvent",
	[Remotes.Names.CurrencyUpdated] = "RemoteEvent",
	[Remotes.Names.PlaceFeedMachine] = "RemoteEvent",
	[Remotes.Names.PlaceFeedMachineResult] = "RemoteEvent",
	[Remotes.Names.PromptInteract] = "RemoteEvent",
}

local function getFolder()
	if folder then return folder end

	local matches = {}
	for _, child in ipairs(ReplicatedStorage:GetChildren()) do
		if child.Name == "Remotes" then
			table.insert(matches, child)
		end
	end

	assert(#matches == 1, string.format("Expected exactly one ReplicatedStorage.Remotes folder, found %d", #matches))
	assert(matches[1]:IsA("Folder"), string.format("ReplicatedStorage.Remotes is a %s", matches[1].ClassName))
	folder = matches[1]
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

	error(string.format("Missing remote %q in ReplicatedStorage.Remotes; declare it in default.project.json", name))
end

function Remotes.validateAll()
	for name in pairs(Definitions) do
		ensure(name)
	end
end

return Remotes
