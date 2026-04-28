-- Hides the AppleTree upgrade prompt on non-owner clients. Each AppleTree
-- model carries an OwnerUserId attribute (set by AppleTree.Setup on the
-- server). The upgrade prompt itself is server-created with the default
-- style; on this client we set Style=Custom for any tree we don't own,
-- which suppresses the default UI locally without rendering anything in
-- its place. Style changes on the client don't replicate, so other
-- clients still see their own trees normally.
--
-- Server-side guards already reject non-owner triggers, so this is purely
-- a visibility nicety.

local Players = game:GetService("Players")

local localPlayer = Players.LocalPlayer

local AppleTreeUI = {}

local watched = {}

local function findUpgradePrompt(model)
	local primary = model.PrimaryPart
	if not primary then return nil end
	local anchor = primary:FindFirstChild("UpgradeAnchor")
	if not anchor then return nil end
	return anchor:FindFirstChildOfClass("ProximityPrompt")
end

local function applyVisibility(model)
	local prompt = findUpgradePrompt(model)
	if not prompt then return end
	local ownerId = model:GetAttribute("OwnerUserId")
	if ownerId and ownerId ~= localPlayer.UserId then
		prompt.Style = Enum.ProximityPromptStyle.Custom
	else
		prompt.Style = Enum.ProximityPromptStyle.Default
	end
end

local function watch(model)
	if watched[model] then return end
	watched[model] = true

	-- The model may arrive before its PrimaryPart attachments + prompt
	-- replicate, so re-apply when descendants change.
	model.DescendantAdded:Connect(function(d)
		if d:IsA("ProximityPrompt") then
			task.defer(function() applyVisibility(model) end)
		end
	end)
	model:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
		applyVisibility(model)
	end)
	applyVisibility(model)

	model.AncestryChanged:Connect(function(_, parent)
		if not parent then watched[model] = nil end
	end)
end

local function consider(inst)
	if inst:IsA("Model") and inst:GetAttribute("FeedType") == "AppleTree" then
		watch(inst)
	end
end

function AppleTreeUI.start()
	for _, d in ipairs(workspace:GetDescendants()) do consider(d) end
	workspace.DescendantAdded:Connect(consider)
end

return AppleTreeUI
