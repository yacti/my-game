-- Single entry point for resolving RemoteEvents/RemoteFunctions so code never
-- types remote names as raw strings in more than one place.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}
local cache = {}
local folder

local function getFolder()
	folder = folder or ReplicatedStorage:WaitForChild("Remotes")
	return folder
end

function Remotes.get(name)
	local remote = cache[name]
	if not remote then
		remote = getFolder():WaitForChild(name)
		cache[name] = remote
	end
	return remote
end

return Remotes
