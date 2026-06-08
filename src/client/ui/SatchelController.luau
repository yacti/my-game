local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SatchelController = {}

function SatchelController.start()
	local satchelRoot = ReplicatedStorage:WaitForChild("Satchel")
	local loader = satchelRoot:WaitForChild("SatchelLoader")
	local satchelModule = loader:WaitForChild("Satchel")

	-- The vendored RunContext loader is disabled; the app controller owns startup.
	require(satchelModule)
end

return SatchelController
