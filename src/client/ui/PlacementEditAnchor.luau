-- Client-local Attachment centered on a placeable's primary-part bottom, so the
-- PlacementEdit billboard rides a deterministic anchor instead of tall model
-- bounds. The attachment lives in the host part's object space, so it follows
-- drags and yaw rotation rigidly.

local PlacementEditAnchor = {}

local ANCHOR_NAME = "__PlacementEditAnchor"

local function firstBasePart(root)
	if root:IsA("BasePart") then
		return root
	end
	if root:IsA("Model") then
		for _, descendant in ipairs(root:GetDescendants()) do
			if descendant:IsA("BasePart") then
				return descendant
			end
		end
	end
	return nil
end

local function primaryPartBottomCenter(part)
	return (part.CFrame * CFrame.new(0, -part.Size.Y / 2, 0)).Position
end

-- Returns an Attachment at the target primary-part bottom center, or nil when
-- the target has no BasePart yet. Reuses an existing anchor on repeat calls
-- and refreshes its position for the target's current primary part.
function PlacementEditAnchor.Attach(target)
	local host = firstBasePart(target)
	if target:IsA("Model") and target.PrimaryPart then
		host = target.PrimaryPart
	end
	if not host then
		return nil
	end

	local attachment = host:FindFirstChild(ANCHOR_NAME)
	if not (attachment and attachment:IsA("Attachment")) then
		attachment = Instance.new("Attachment")
		attachment.Name = ANCHOR_NAME
		attachment.Parent = host
	end
	attachment.WorldPosition = primaryPartBottomCenter(host)
	return attachment
end

return PlacementEditAnchor
