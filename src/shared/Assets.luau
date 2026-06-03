local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = {}

Assets.FolderName = "Assets"

Assets.Names = {
	Crates = "Crates",
	FeedMachines = "FeedMachines",
	FeedMachineTool = "FeedMachineTool",
	Food = "Food",
	Misc = "Misc",
	PetModels = "PetModels",
	Seeds = "Seeds",
	SeedTool = "SeedTool",
	Shovel = "Shovel",
	VFX = "VFX",
}

local function waitForChild(parent, name, timeout)
	if timeout == nil then
		return parent:WaitForChild(name)
	end
	return parent:WaitForChild(name, timeout)
end

function Assets.FindRoot()
	return ReplicatedStorage:FindFirstChild(Assets.FolderName)
end

function Assets.WaitForRoot(timeout)
	return waitForChild(ReplicatedStorage, Assets.FolderName, timeout)
end

function Assets.Find(name)
	local root = Assets.FindRoot()
	return root and root:FindFirstChild(name) or nil
end

function Assets.WaitFor(name, timeout)
	local root = Assets.WaitForRoot(timeout)
	if not root then
		return nil
	end
	return waitForChild(root, name, timeout)
end

return Assets
