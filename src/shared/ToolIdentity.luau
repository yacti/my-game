local HttpService = game:GetService("HttpService")

local State = require(script.Parent:WaitForChild("State"))

local ToolIdentity = {}

function ToolIdentity.IsValidGuid(guid)
	return type(guid) == "string" and guid ~= ""
end

function ToolIdentity.GuidOf(tool)
	if not (tool and tool:IsA("Tool")) then
		return nil
	end

	local guid = tool:GetAttribute(State.Tool.Guid)
	return ToolIdentity.IsValidGuid(guid) and guid or nil
end

function ToolIdentity.AssignGuid(tool)
	if not (tool and tool:IsA("Tool")) then
		return nil
	end

	-- Inventory tools must never leave the player: blocks the engine's
	-- Backspace drop and the throw-on-death behavior.
	tool.CanBeDropped = false

	local guid = HttpService:GenerateGUID(false)
	tool:SetAttribute(State.Tool.Guid, guid)
	return guid
end

function ToolIdentity.EnsureGuid(tool)
	return ToolIdentity.GuidOf(tool) or ToolIdentity.AssignGuid(tool)
end

function ToolIdentity.FindEquippedByGuid(player, guid, predicate)
	if not (player and ToolIdentity.IsValidGuid(guid)) then
		return nil
	end

	local character = player.Character
	if not character then
		return nil
	end

	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool")
			and ToolIdentity.GuidOf(child) == guid
			and (predicate == nil or predicate(child)) then
			return child
		end
	end

	return nil
end

function ToolIdentity.DestroyIfGuidMatches(tool, expectedGuid)
	if not (tool and tool:IsA("Tool") and tool.Parent) then
		return false
	end
	if not ToolIdentity.IsValidGuid(expectedGuid) or ToolIdentity.GuidOf(tool) ~= expectedGuid then
		return false
	end

	tool:Destroy()
	return true
end

return ToolIdentity
