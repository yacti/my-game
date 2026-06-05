local BillboardGuiTemplates = require(script.Parent:WaitForChild("BillboardGuiTemplates"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local XPBillboardTemplate = {}

local TEMPLATE_NAME = "XPBillboard"
local LABEL_NAME = "XPLabel"

local warnedMissingTemplate = {}
local warnedMissingLabel = {}

local function warnOnce(seen, key, message)
	if seen[key] then return end
	warn(message)
	seen[key] = true
end

function XPBillboardTemplate.Clone(context)
	context = context or "XPBillboardTemplate"

	local template = BillboardGuiTemplates.Find(TEMPLATE_NAME)
	if not (template and template:IsA("BillboardGui")) then
		warnOnce(
			warnedMissingTemplate,
			context,
			string.format("[%s] Missing %s BillboardGui", context, BillboardGuiTemplates.Path(TEMPLATE_NAME))
		)
		return nil, nil
	end

	local gui = template:Clone()
	UiEffects.BindBillboardPop(gui)
	local label = gui:FindFirstChild(LABEL_NAME, true)
	if not (label and label:IsA("TextLabel")) then
		warnOnce(
			warnedMissingLabel,
			context,
			string.format("[%s] %s missing %s TextLabel", context, TEMPLATE_NAME, LABEL_NAME)
		)
		gui:Destroy()
		return nil, nil
	end

	return gui, label
end

return XPBillboardTemplate
