local PlacementEditBillboard = {}

local WORLD_Y_OFFSET = -1.5

local BASE_OFFSET = Vector3.new(0, WORLD_Y_OFFSET, 0)

function PlacementEditBillboard.Apply(billboard)
	if not (billboard and billboard:IsA("BillboardGui")) then
		return nil
	end

	billboard.AlwaysOnTop = true
	billboard.StudsOffset = Vector3.zero
	billboard.StudsOffsetWorldSpace = BASE_OFFSET
end

return PlacementEditBillboard
