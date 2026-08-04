local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = {}

Assets.FolderName = "Assets"

Assets.Names = {
	-- Templates for admin-toggled world events (MrAlienEvent), cloned into
	-- Workspace.Map while the event is up rather than authored there.
	AdminEvents = "AdminEvents",
	Cosmetics = "Cosmetics",
	CosmeticTool = "CosmeticTool",
	Crates = "Crates",
	FeedMachines = "FeedMachines",
	FeedMachineTool = "FeedMachineTool",
	Food = "Food",
	-- Templates for scheduled world events (MerchantEvent), cloned into
	-- Workspace.Map for the event's window. Distinct from AdminEvents: these
	-- come and go on a cadence rather than on an operator toggle.
	GameEvents = "GameEvents",
	Misc = "Misc",
	Mutations = "Mutations",
	PetModels = "PetModels",
	PetSkins = "PetSkins",
	PetSkinTool = "PetSkinTool",
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
