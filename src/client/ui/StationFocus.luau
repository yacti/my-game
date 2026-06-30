local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MailboxConfig = require(Shared:WaitForChild("MailboxConfig"))
local RollConfig = require(Shared:WaitForChild("RollConfig"))

local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))

local StationFocus = {}

StationFocus.Stations = {
	None = "None",
	Roll = "Roll",
	Mailbox = "Mailbox",
}

local player = Players.LocalPlayer

local function rootPart()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root or nil
end

local function rollButtonForPlot(plot)
	local rollArea = plot and plot:FindFirstChild("RollArea")
	local buttonFolder = rollArea and rollArea:FindFirstChild("Button")
	local button = buttonFolder and buttonFolder:FindFirstChild("Button")
	return button and button:IsA("BasePart") and button or nil
end

local function mailboxForPlot(plot)
	local signs = plot and plot:FindFirstChild(MailboxConfig.SignsFolderName)
	return signs and signs:FindFirstChild(MailboxConfig.MailboxName) or nil
end

local function instancePosition(instance)
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		local cframe = instance:GetBoundingBox()
		return cframe.Position
	end
	local part = instance:FindFirstChildWhichIsA("BasePart", true)
	return part and part.Position or nil
end

local function distanceToPosition(root, position)
	return root and position and (root.Position - position).Magnitude or nil
end

function StationFocus.RollButtonForPlot(plot)
	return rollButtonForPlot(plot)
end

function StationFocus.MailboxForPlot(plot)
	return mailboxForPlot(plot)
end

function StationFocus.InstancePosition(instance)
	return instancePosition(instance)
end

function StationFocus.ActiveStation()
	local root = rootPart()
	local plot = PlotResolver.ResolveForPlayer(player)
	if not (root and plot) then
		return StationFocus.Stations.None
	end

	local rollDistance = distanceToPosition(root, instancePosition(rollButtonForPlot(plot)))
	local mailboxDistance = distanceToPosition(root, instancePosition(mailboxForPlot(plot)))
	local rollInRange = rollDistance ~= nil and rollDistance <= RollConfig.Button.InteractionDistance
	local mailboxInRange = mailboxDistance ~= nil and mailboxDistance <= MailboxConfig.InteractionDistance

	if rollInRange and mailboxInRange then
		if mailboxDistance < rollDistance then
			return StationFocus.Stations.Mailbox
		end
		return StationFocus.Stations.Roll
	end
	if rollInRange then
		return StationFocus.Stations.Roll
	end
	if mailboxInRange then
		return StationFocus.Stations.Mailbox
	end
	return StationFocus.Stations.None
end

function StationFocus.IsRollActive()
	return StationFocus.ActiveStation() == StationFocus.Stations.Roll
end

function StationFocus.IsMailboxActive()
	return StationFocus.ActiveStation() == StationFocus.Stations.Mailbox
end

return StationFocus
