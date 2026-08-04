-- Point-in-part containment, shared so the client and the server agree on
-- "inside the volume".
--
-- Shop-style triggers are an invisible BasePart the player walks into, tested
-- as an oriented box rather than a radius so a rotated or non-cubic stall
-- footprint behaves the way it looks. The client polls it to auto-open a panel;
-- the server re-runs the identical test before accepting the request, so a
-- client that lies about being in range is rejected on the same maths rather
-- than a near-miss approximation.
--
-- ShopPanelController and GearShopService each carry their own inline copy of
-- this from before it was shared. They still work and are deliberately left
-- alone; new callers should use this.
local PartVolume = {}

function PartVolume.Contains(part, position)
	if not (part and typeof(part) == "Instance" and part:IsA("BasePart")) then
		return false
	end
	if typeof(position) ~= "Vector3" then
		return false
	end

	local localPosition = part.CFrame:PointToObjectSpace(position)
	local half = part.Size * 0.5
	return math.abs(localPosition.X) <= half.X
		and math.abs(localPosition.Y) <= half.Y
		and math.abs(localPosition.Z) <= half.Z
end

-- Convenience wrapper: most callers are asking about a player's character.
function PartVolume.ContainsPlayer(part, player)
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return false
	end
	return PartVolume.Contains(part, root.Position)
end

return PartVolume
