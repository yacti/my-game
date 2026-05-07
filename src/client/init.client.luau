-- Hide Roblox's default backpack so Satchel is the only inventory UI.
local StarterGui = game:GetService("StarterGui")
StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)

local ui = script:WaitForChild("ui")

require(ui:WaitForChild("HudController")).start()
require(ui:WaitForChild("PetBillboards")).start()
require(ui:WaitForChild("ToolStatsBillboard")).start()
require(ui:WaitForChild("SlotXPBillboard")).start()
require(ui:WaitForChild("AppleTreeSlotVisuals")).start()
require(ui:WaitForChild("ProcessorVisuals")).start()
require(ui:WaitForChild("FeedPlacement")).start()
require(ui:WaitForChild("LocalPrompts")).start()
