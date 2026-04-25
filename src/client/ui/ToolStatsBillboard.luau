-- Renders an xp (and optional multiplier) badge above any equipped food
-- Tool. Built per-viewer locally under the Tool's Handle, so the billboard
-- isn't replicated and can be restyled or hidden without touching the
-- server.
--
-- Server owns the data (XP, optional XPMultiplier attributes set on the
-- Tool); this module only reads them and rebuilds the label when they
-- change. The multiplier is only shown when it's strictly greater than 1.
--
-- We watch Workspace descendants — a Tool only reaches Workspace when it's
-- equipped (parented to a Character), which is exactly when the badge
-- should be visible.

local Workspace = game:GetService("Workspace")

local ToolStatsBillboard = {}

local function isFoodTool(obj)
	return obj:IsA("Tool") and obj:GetAttribute("FoodType") ~= nil
end

local function build(tool)
	local handle = tool:FindFirstChild("Handle")
	if not handle then return end
	if handle:FindFirstChild("Stats") then return end

	local gui = Instance.new("BillboardGui")
	gui.Name        = "Stats"
	gui.Adornee     = handle
	gui.Size        = UDim2.new(0, 90, 0, 28)
	gui.StudsOffset = Vector3.new(0, handle.Size.Y / 2 + 1, 0)
	gui.AlwaysOnTop = true

	local label = Instance.new("TextLabel")
	label.Size                   = UDim2.fromScale(1, 1)
	label.BackgroundColor3       = Color3.fromRGB(30, 30, 30)
	label.BackgroundTransparency = 0.2
	label.TextColor3             = Color3.fromRGB(255, 255, 255)
	label.Font                   = Enum.Font.GothamBold
	label.TextScaled             = true
	label.Parent                 = gui
	Instance.new("UICorner", label).CornerRadius = UDim.new(0, 6)

	local function render()
		local xp   = tool:GetAttribute("XP") or 0
		local mult = tool:GetAttribute("XPMultiplier") or 1
		if mult > 1 then
			label.Text = string.format("%sx, %dxp", tostring(mult), xp)
		else
			label.Text = string.format("%dxp", xp)
		end
	end
	render()
	tool:GetAttributeChangedSignal("XP"):Connect(render)
	tool:GetAttributeChangedSignal("XPMultiplier"):Connect(render)

	gui.Parent = handle
end

function ToolStatsBillboard.start()
	for _, d in ipairs(Workspace:GetDescendants()) do
		if isFoodTool(d) then build(d) end
	end
	Workspace.DescendantAdded:Connect(function(d)
		if isFoodTool(d) then build(d) end
	end)
end

return ToolStatsBillboard
