local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BillboardGuiTemplates = {}

local UI_FOLDER_NAME = "UI"
local BILLBOARD_FOLDER_NAME = "BillboardGUIs"

function BillboardGuiTemplates.Path(templateName)
	return string.format("ReplicatedStorage.%s.%s.%s", UI_FOLDER_NAME, BILLBOARD_FOLDER_NAME, tostring(templateName))
end

function BillboardGuiTemplates.Find(templateName)
	local uiFolder = ReplicatedStorage:FindFirstChild(UI_FOLDER_NAME)
	local billboardFolder = uiFolder and uiFolder:FindFirstChild(BILLBOARD_FOLDER_NAME)
	return billboardFolder and billboardFolder:FindFirstChild(templateName) or nil
end

function BillboardGuiTemplates.WaitFor(templateName, timeoutSeconds)
	local uiFolder = ReplicatedStorage:WaitForChild(UI_FOLDER_NAME, timeoutSeconds)
	local billboardFolder = uiFolder and uiFolder:WaitForChild(BILLBOARD_FOLDER_NAME, timeoutSeconds)
	return billboardFolder and billboardFolder:WaitForChild(templateName, timeoutSeconds) or nil
end

return BillboardGuiTemplates
