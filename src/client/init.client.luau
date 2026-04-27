print("[Client] UI bootstrap")

local ui = script:WaitForChild("ui")

require(ui:WaitForChild("HudController")).start()
require(ui:WaitForChild("PetBillboards")).start()
require(ui:WaitForChild("ToolStatsBillboard")).start()
require(ui:WaitForChild("TimedSlotBillboard")).start()
require(ui:WaitForChild("FeedPlacement")).start()
