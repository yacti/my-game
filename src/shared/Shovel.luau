local Shovel = {}

Shovel.ToolName = "Shovel"
Shovel.ToolKindAttribute = "ToolKind"
Shovel.ToolKind = "Shovel"

function Shovel.IsTool(item)
	return item ~= nil
		and item:IsA("Tool")
		and item.Name == Shovel.ToolName
		and item:GetAttribute(Shovel.ToolKindAttribute) == Shovel.ToolKind
end

return Shovel
