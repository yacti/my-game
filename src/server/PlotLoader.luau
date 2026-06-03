local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Assets = require(ReplicatedStorage.Shared:WaitForChild("Assets"))

local PlotLoader = {}

local MISC_FOLDER_NAME = "Misc"
local PLOT_TEMPLATE_NAME = "PlotTemplate"
local MARKERS_FOLDER_NAME = "PlotTemplates"
local RUNTIME_FOLDER_NAME = "Plots"
local PLOT_NAME_PATTERN = "^Plot(%d+)$"

local function fail(message)
	error("[PlotLoader] " .. message, 2)
end

local function expectChild(parent, name, className)
	local child = parent and parent:FindFirstChild(name)
	if not child then
		fail(string.format("Missing %s.%s", parent and parent:GetFullName() or "nil", name))
	end
	if className and not child:IsA(className) then
		fail(string.format("%s is %s, expected %s", child:GetFullName(), child.ClassName, className))
	end
	return child
end

local function plotNumberForMarker(marker)
	return tonumber(marker.Name:match(PLOT_NAME_PATTERN))
end

local function collectMarkers(folder)
	local markers = {}
	local seenNumbers = {}

	for _, marker in ipairs(folder:GetChildren()) do
		if not marker:IsA("BasePart") then
			fail(string.format("%s is %s, expected numbered BasePart loading pad", marker:GetFullName(), marker.ClassName))
		end

		local plotNumber = plotNumberForMarker(marker)
		if not plotNumber then
			fail(marker:GetFullName() .. " must be named Plot<number>")
		end
		if seenNumbers[plotNumber] then
			fail(string.format(
				"Duplicate plot loading pad number %d on %s and %s",
				plotNumber,
				seenNumbers[plotNumber]:GetFullName(),
				marker:GetFullName()
			))
		end

		seenNumbers[plotNumber] = marker
		markers[#markers + 1] = {
			number = plotNumber,
			marker = marker,
		}
	end

	table.sort(markers, function(a, b)
		return a.number < b.number
	end)

	for index, record in ipairs(markers) do
		if record.number ~= index then
			fail(string.format("Plot loading pads must be numbered contiguously from 1; expected Plot%d, found Plot%d", index, record.number))
		end
	end

	if #markers == 0 then
		fail(folder:GetFullName() .. " must contain at least one numbered plot loading pad")
	end

	return markers
end

local function runtimePlotsFolder()
	local folder = Workspace:FindFirstChild(RUNTIME_FOLDER_NAME)
	if folder then
		if not folder:IsA("Folder") then
			fail(string.format("%s is %s, expected Folder", folder:GetFullName(), folder.ClassName))
		end
		folder:ClearAllChildren()
	else
		folder = Instance.new("Folder")
		folder.Name = RUNTIME_FOLDER_NAME
		folder.Parent = Workspace
	end
	return folder
end

function PlotLoader.Load()
	local assetRoot = expectChild(ReplicatedStorage, Assets.FolderName, "Folder")
	local misc = expectChild(assetRoot, MISC_FOLDER_NAME, "Folder")
	local template = expectChild(misc, PLOT_TEMPLATE_NAME, "Model")
	local markerFolder = expectChild(Workspace, MARKERS_FOLDER_NAME, "Folder")
	local markers = collectMarkers(markerFolder)
	local referenceMarker = markers[1].marker

	local markerToTemplatePivot = referenceMarker.CFrame:ToObjectSpace(template:GetPivot())
	local plotsFolder = runtimePlotsFolder()

	for _, record in ipairs(markers) do
		record.marker.Anchored = true
		record.marker.Transparency = 1
		record.marker.CanCollide = false
		record.marker.CanQuery = false
		record.marker.CanTouch = false
		record.marker.CastShadow = false

		local plot = template:Clone()
		plot.Name = "Plot" .. tostring(record.number)
		plot:PivotTo(record.marker.CFrame * markerToTemplatePivot)
		plot.Parent = plotsFolder
	end

	return plotsFolder, #markers
end

return PlotLoader
