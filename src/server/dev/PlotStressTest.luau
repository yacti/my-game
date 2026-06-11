local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Server = script.Parent.Parent
local FeedMachines = require(Server:WaitForChild("feedMachines"))
local PetMotionService = require(Server:WaitForChild("PetMotionService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local PlotGridService = require(Server:WaitForChild("PlotGridService"))
local PlotService = require(Server:WaitForChild("PlotService"))
local TelemetryService = require(Server:WaitForChild("TelemetryService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local PlotStressTest = {}

local SERVER_FOLDER = ServerScriptService:WaitForChild("Server")

local ATTR_ENABLED = "PlotStressTestEnabled"
local ATTR_DISABLE_TUTORIAL = "PlotStressTestDisableTutorial"
local ATTR_ACTIVE_COLLECTION = "PlotStressTestActiveCollection"
local ATTR_TREE_CLICK_INTERVAL = "PlotStressTestTreeClickIntervalSeconds"
local ATTR_PLOT_COUNT = "PlotStressTestPlotCount"
local ATTR_PETS_PER_PLOT = "PlotStressTestPetsPerPlot"
local ATTR_PATCHES_PER_PLOT = "PlotStressTestPatchesPerPlot"
local ATTR_TREES_PER_PLOT = "PlotStressTestTreesPerPlot"
local ATTR_DURATION_SECONDS = "PlotStressTestDurationSeconds"
local ATTR_METRICS_SECONDS = "PlotStressTestMetricsSeconds"
local ATTR_PET_ID = "PlotStressTestPetId"
local ATTR_PATCH_FEED_TYPE = "PlotStressTestPatchFeedType"
local ATTR_TREE_FEED_TYPE = "PlotStressTestTreeFeedType"
local CLIENT_REMOTE_NAME = "PlotStressTestCommand"

local RUN_ID_ATTR = "PlotStressTestRunId"
local CREATED_TOOL_ATTR = "PlotStressTestCreatedTool"
-- Server-driven pickup rates grant tools far faster than any real player
-- could; without a live cap the owner's backpack grows to thousands of tools
-- (O(n^2) rescans + replication flood) and poisons active-run metrics.
local MAX_LIVE_CREATED_TOOLS = 200

local DEFAULT_CONFIG = {
	PlotCount = 8,
	PetsPerPlot = 10,
	PatchesPerPlot = 300,
	TreesPerPlot = 30,
	PetId = "Pet1",
	PatchFeedType = "PumpkinPatch",
	TreeFeedType = "AppleTree",
	DurationSeconds = 180,
	MetricsIntervalSeconds = 5,
	OwnerWaitSeconds = 45,
	PlacementSpacing = 4,
	TreeClickIntervalSeconds = 0.22,
	ActiveCollection = true,
	DisableTutorial = true,
}

-- Population yields: cap synchronous placement bursts so the harness does not
-- manufacture multi-second frames that real gameplay cannot produce.
local PLACEMENTS_PER_YIELD = 25
local PETS_PER_YIELD = 5

local activeRun = nil
local watchConnection = nil
local clientRemoteConnection = nil
local clientRemote = nil
local clientSession = nil
local clientSessionExpiresAt = 0
local clientTreeClickRunsByUserId = {}
local playerRemovingConnection = nil

local function numberAttr(name, fallback, minimum)
	local value = SERVER_FOLDER:GetAttribute(name)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return fallback
	end
	if minimum ~= nil and value < minimum then
		return fallback
	end
	return value
end

local function booleanAttr(name, fallback)
	local value = SERVER_FOLDER:GetAttribute(name)
	if type(value) == "boolean" then
		return value
	end
	return fallback
end

local function stringAttr(name, fallback)
	local value = SERVER_FOLDER:GetAttribute(name)
	if type(value) == "string" and value ~= "" then
		return value
	end
	return fallback
end

local function readConfig(overrides)
	local config = table.clone(DEFAULT_CONFIG)
	config.PlotCount = math.floor(numberAttr(ATTR_PLOT_COUNT, config.PlotCount, 1))
	config.PetsPerPlot = math.floor(numberAttr(ATTR_PETS_PER_PLOT, config.PetsPerPlot, 0))
	config.PatchesPerPlot = math.floor(numberAttr(ATTR_PATCHES_PER_PLOT, config.PatchesPerPlot, 0))
	config.TreesPerPlot = math.floor(numberAttr(ATTR_TREES_PER_PLOT, config.TreesPerPlot, 0))
	config.DurationSeconds = numberAttr(ATTR_DURATION_SECONDS, config.DurationSeconds, 1)
	config.MetricsIntervalSeconds = numberAttr(ATTR_METRICS_SECONDS, config.MetricsIntervalSeconds, 1)
	config.PetId = stringAttr(ATTR_PET_ID, config.PetId)
	config.PatchFeedType = stringAttr(ATTR_PATCH_FEED_TYPE, config.PatchFeedType)
	config.TreeFeedType = stringAttr(ATTR_TREE_FEED_TYPE, config.TreeFeedType)
	config.ActiveCollection = booleanAttr(ATTR_ACTIVE_COLLECTION, config.ActiveCollection)
	config.TreeClickIntervalSeconds = numberAttr(ATTR_TREE_CLICK_INTERVAL, config.TreeClickIntervalSeconds, 0.05)
	config.DisableTutorial = booleanAttr(ATTR_DISABLE_TUTORIAL, config.DisableTutorial)

	if type(overrides) == "table" then
		for key, value in pairs(overrides) do
			config[key] = value
		end
	end

	return config
end

local function sortedRuntimePlots()
	local folder = Workspace:FindFirstChild("Plots")
	if not folder then
		return {}
	end

	local plots = {}
	for _, plot in ipairs(folder:GetChildren()) do
		if plot:IsA("Model") then
			plots[#plots + 1] = plot
		end
	end
	table.sort(plots, function(a, b)
		local aNumber = tonumber(a.Name:match("%d+$")) or math.huge
		local bNumber = tonumber(b.Name:match("%d+$")) or math.huge
		if aNumber ~= bNumber then
			return aNumber < bNumber
		end
		return a.Name < b.Name
	end)
	return plots
end

local function waitForOwner(config)
	local deadline = os.clock() + config.OwnerWaitSeconds
	while os.clock() < deadline do
		for _, player in ipairs(Players:GetPlayers()) do
			local plot = PlotService.GetPlayerPlot(player)
			if plot then
				return player, plot
			end
		end
		task.wait(0.25)
	end
	return nil, nil
end

local function choosePlots(ownerPlot, maxCount)
	local selected = {}
	if ownerPlot then
		selected[#selected + 1] = ownerPlot
	end

	for _, plot in ipairs(sortedRuntimePlots()) do
		if plot ~= ownerPlot then
			selected[#selected + 1] = plot
			if #selected >= maxCount then
				break
			end
		end
	end

	while #selected > maxCount do
		table.remove(selected)
	end
	return selected
end

local function emit(eventName, fields)
	TelemetryService.Record(eventName, fields)
	print("[PlotStressTest] " .. eventName)
end

local MAX_CAPTURED_MESSAGES = 20

local function newRun(config)
	return {
		id = HttpService:GenerateGUID(false),
		config = config,
		startedAt = os.clock(),
		connections = {},
		heartbeatSamples = {},
		capturedMessages = {},
		pets = {},
		feeds = {},
		trees = {},
		plots = {},
		syntheticPlots = {},
		toolBaseline = {},
		createdTools = {},
		createdToolOrder = {},
		createdToolHead = 1,
		createdToolTail = 0,
		ownerPlot = nil,
		stopRequested = false,
		counters = {
			unlockedGridCells = 0,
			petsCreated = 0,
			patchesCreated = 0,
			treesCreated = 0,
			petsMissing = 0,
			patchesMissing = 0,
			treesMissing = 0,
			setupSeconds = 0,
			treeClickAttempts = 0,
			treeClickSuccesses = 0,
			treePickupAttempts = 0,
			treePickupSuccesses = 0,
			warnings = 0,
			errors = 0,
		},
	}
end

local function recordLogMessage(run, message, messageType)
	if messageType == Enum.MessageType.MessageWarning then
		run.counters.warnings += 1
	elseif messageType == Enum.MessageType.MessageError then
		run.counters.errors += 1
	else
		return
	end

	-- Skip the harness's own output so shortfall warnings don't recurse into
	-- the capture buffer and drown real signals.
	if type(message) == "string" and message:find("[PlotStressTest", 1, true) then
		return
	end
	if #run.capturedMessages >= MAX_CAPTURED_MESSAGES then
		return
	end
	run.capturedMessages[#run.capturedMessages + 1] = string.format(
		"[%s +%.1fs] %s",
		messageType == Enum.MessageType.MessageError and "error" or "warn",
		os.clock() - run.startedAt,
		tostring(message)
	)
end

local function dumpCapturedMessages(run)
	if #run.capturedMessages == 0 then
		return
	end
	print(string.format(
		"[PlotStressTest] Captured %d warning/error message(s) (warnings=%d errors=%d):",
		#run.capturedMessages,
		run.counters.warnings,
		run.counters.errors
	))
	for index, message in ipairs(run.capturedMessages) do
		print(string.format("[PlotStressTest]   %02d. %s", index, message))
	end
end

local function disconnectAll(connections)
	for _, connection in ipairs(connections) do
		if connection then
			connection:Disconnect()
		end
	end
	table.clear(connections)
end

local function addUnique(array, value)
	for _, existing in ipairs(array) do
		if existing == value then
			return false
		end
	end
	array[#array + 1] = value
	return true
end

local function userKey(player)
	return player and player.UserId or nil
end

local function rememberOwnerTools(run, player)
	local baseline = {}
	run.toolBaseline[player] = baseline

	local function remember(container)
		if not container then
			return
		end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") then
				baseline[child] = true
			end
		end
	end

	remember(player:FindFirstChildOfClass("Backpack"))
	remember(player.Character)
end

-- Explicit head/tail indices: clearing consumed slots leaves holes, so the
-- length operator cannot be trusted on this array.
local function pruneCreatedTools(run)
	local order = run.createdToolOrder
	while run.createdToolTail - run.createdToolHead + 1 > MAX_LIVE_CREATED_TOOLS do
		local tool = order[run.createdToolHead]
		order[run.createdToolHead] = nil
		run.createdToolHead += 1
		if tool and run.createdTools[tool] then
			run.createdTools[tool] = nil
			if tool.Parent then
				tool:Destroy()
			end
		end
	end
end

local function tagNewOwnerTools(run, player)
	local baseline = run.toolBaseline[player]
	if not baseline then
		return
	end

	local function tag(container)
		if not container then
			return
		end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and not baseline[child] and Food.IsFood(child) then
				child:SetAttribute(CREATED_TOOL_ATTR, run.id)
				run.createdTools[child] = true
				run.createdToolTail += 1
				run.createdToolOrder[run.createdToolTail] = child
				baseline[child] = true
			end
		end
	end

	tag(player:FindFirstChildOfClass("Backpack"))
	tag(player.Character)
	pruneCreatedTools(run)
end

local function cleanupTools(run)
	for tool in pairs(run.createdTools) do
		if tool and tool.Parent and tool:GetAttribute(CREATED_TOOL_ATTR) == run.id then
			tool:Destroy()
		end
	end
	table.clear(run.createdTools)
	table.clear(run.createdToolOrder)
	run.createdToolHead = 1
	run.createdToolTail = 0
end

local function destroyStressFeedsOn(plot)
	if not plot then
		return 0
	end

	local destroyed = 0
	for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
		if feed:GetAttribute(RUN_ID_ATTR) ~= nil then
			feed:Destroy()
			destroyed += 1
		end
	end
	return destroyed
end

local function destroyStressPetsOn(plot)
	if not plot then
		return 0
	end

	local destroyed = 0
	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		if pet:GetAttribute(RUN_ID_ATTR) ~= nil then
			pet:Destroy()
			destroyed += 1
		end
	end
	return destroyed
end

local function resetPlotAfterRun(plot, ownerPlot)
	destroyStressPetsOn(plot)
	destroyStressFeedsOn(plot)
	if plot == ownerPlot then
		local owner = nil
		for _, player in ipairs(Players:GetPlayers()) do
			if PlotService.GetPlayerPlot(player) == plot then
				owner = player
				break
			end
		end
		local profile = owner and PlayerDataService.GetProfile(owner)
		if profile then
			PlotGridService.ApplyProfileState(plot, profile)
		else
			PlotGridService.ResetPlotState(plot)
		end
	else
		PlotGridService.ResetVacantPlotState(plot)
	end
end

local function allUnlockKeys(index)
	local keys = {}
	for _, cell in ipairs(index.unlockableCells or {}) do
		keys[#keys + 1] = cell.coordKey
	end
	return keys
end

local function applyMaxGrid(plot)
	local index = PlotGridService.BuildIndex(plot)
	if not index then
		return false, "no-grid-index", 0
	end

	local profile = {
		Data = {
			UnlockedGridKeys = allUnlockKeys(index),
		},
	}
	local ok, reason = PlotGridService.ApplyProfileState(plot, profile)
	return ok == true, reason, #profile.Data.UnlockedGridKeys
end

local function candidatePositions(plot, spacing)
	local minX, maxX, minZ, maxZ = PlotGridService.GetUnlockedLocalBounds(plot, spacing, spacing)
	if not minX then
		return {}
	end

	local positions = {}
	local z = minZ
	while z <= maxZ do
		local x = minX
		while x <= maxX do
			positions[#positions + 1] = {
				lx = x,
				lz = z,
			}
			x += spacing
		end
		z += spacing
	end
	return positions
end

local function nextPetIndex(plot)
	local maxIndex = 0
	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		local index = pet:GetAttribute(State.Pet.Index)
		if type(index) == "number" and index > maxIndex then
			maxIndex = index
		end
	end
	return maxIndex + 1
end

local function placePetBatch(run, plot, petId, count)
	local floor = PlotService.GetFloor(plot)
	if not floor then
		return 0, count
	end

	local rng = Random.new(math.floor(os.clock() * 1000000) + #run.pets * 31)
	local created = 0
	local petIndex = nextPetIndex(plot)

	for attempt = 1, count do
		local lx, lz = PlotGridService.RandomUnlockedPoint(plot, rng, 0, 0)
		if not lx or not lz then
			lx, lz = PlotGridService.FirstUnlockedPoint(plot, 0, 0)
		end
		if not lx or not lz then
			-- No unlocked point on the whole plot; permanent for this batch.
			warn(string.format("[PlotStressTest] %s has no unlocked point for pets; %d not placed", plot.Name, count - created))
			break
		end

		local pet = PlotService.CreatePet(petId, petIndex, 0, floor, lx, lz, 0)
		if not pet then
			-- Missing template/definition; permanent for this batch.
			warn(string.format("[PlotStressTest] CreatePet failed for %s on %s; %d not placed", tostring(petId), plot.Name, count - created))
			break
		end

		if PlotService.FitPetOnUnlockedGrid(plot, pet, lx, lz, 0, true) then
			pet:SetAttribute(RUN_ID_ATTR, run.id)
			pet:SetAttribute(State.Pet.Money, 0)
			pet:SetAttribute(State.Pet.XP, 0)
			pet.Parent = plot
			run.pets[#run.pets + 1] = pet
			PetMotionService.Register(plot, pet)

			created += 1
			petIndex += 1
		else
			-- Point-specific failure; count the miss and keep trying the rest.
			pet:Destroy()
			warn(string.format("[PlotStressTest] Pet fit failed on %s (attempt %d/%d)", plot.Name, attempt, count))
		end

		if attempt % PETS_PER_YIELD == 0 then
			task.wait()
		end
	end

	return created, count - created
end

local function placeOneFeed(plot, owner, feedType, feedIndex, lx, lz, run)
	if not PlotService.FeedPlacementFitsOnFloor(plot, feedType, lx, lz, 0) then
		return nil, "does-not-fit"
	end
	if PlotService.FeedPlacementOverlaps(plot, feedType, lx, lz, 0) then
		return nil, "overlaps"
	end

	local feed = PlotService.PlaceFeedWithIndex(plot, feedType, feedIndex, lx, lz, 0)
	if not feed then
		return nil, "place-failed"
	end

	feed:SetAttribute(RUN_ID_ATTR, run.id)
	local setupOk, setupCode = FeedMachines.Setup(feed, plot, owner)
	if not setupOk then
		feed:Destroy()
		return nil, setupCode or "setup-failed"
	end

	run.feeds[#run.feeds + 1] = feed
	return feed, "ok"
end

local function placeFeedBatch(run, plot, owner, feedType, count, spacing)
	local created = 0
	local feedIndex = PlotService.NextFeedIndex(plot)
	local positions = candidatePositions(plot, spacing)

	for _, position in ipairs(positions) do
		if created >= count then
			break
		end

		local feed = placeOneFeed(plot, owner, feedType, feedIndex, position.lx, position.lz, run)
		if feed then
			created += 1
			feedIndex += 1
			if FeedMachines.GetClass(feedType) == "Tree" then
				run.trees[#run.trees + 1] = feed
			end
			if created % PLACEMENTS_PER_YIELD == 0 then
				task.wait()
			end
		end
	end

	return created, count - created
end

local function preparePlot(run, plot, owner, ownerPlot, config)
	destroyStressPetsOn(plot)
	destroyStressFeedsOn(plot)

	local gridOk, gridReason, unlockedCount = applyMaxGrid(plot)
	if not gridOk then
		warn(string.format("[PlotStressTest] Could not max-unlock %s: %s", plot.Name, tostring(gridReason)))
		return false
	end

	addUnique(run.plots, plot)
	if plot ~= ownerPlot then
		run.syntheticPlots[plot] = true
	end

	local treeCreated, treeMissing = placeFeedBatch(run, plot, owner, config.TreeFeedType, config.TreesPerPlot, config.PlacementSpacing * 2)
	local patchCreated, patchMissing = placeFeedBatch(run, plot, owner, config.PatchFeedType, config.PatchesPerPlot, config.PlacementSpacing)
	local petCreated, petMissing = placePetBatch(run, plot, config.PetId, config.PetsPerPlot)

	run.counters.unlockedGridCells += unlockedCount
	run.counters.treesCreated += treeCreated
	run.counters.patchesCreated += patchCreated
	run.counters.petsCreated += petCreated
	run.counters.treesMissing += treeMissing
	run.counters.patchesMissing += patchMissing
	run.counters.petsMissing += petMissing

	local summary = string.format(
		"[PlotStressTest] %s populated: pets %d/%d, trees %d/%d, patches %d/%d",
		plot.Name,
		petCreated,
		config.PetsPerPlot,
		treeCreated,
		config.TreesPerPlot,
		patchCreated,
		config.PatchesPerPlot
	)
	if treeMissing > 0 or patchMissing > 0 or petMissing > 0 then
		warn(summary .. " (SHORTFALL)")
	else
		print(summary)
	end
	TelemetryService.Record("plot_stress_plot_populated", {
		runId = run.id,
		plot = plot.Name,
		petsCreated = petCreated,
		petsExpected = config.PetsPerPlot,
		treesCreated = treeCreated,
		treesExpected = config.TreesPerPlot,
		patchesCreated = patchCreated,
		patchesExpected = config.PatchesPerPlot,
	})

	return true
end

local function percentile(sortedValues, ratio)
	if #sortedValues == 0 then
		return 0
	end
	local index = math.clamp(math.ceil(#sortedValues * ratio), 1, #sortedValues)
	return sortedValues[index]
end

local function heartbeatStats(run)
	local samples = table.clone(run.heartbeatSamples)
	table.sort(samples)
	return {
		count = #samples,
		p50Ms = percentile(samples, 0.5),
		p95Ms = percentile(samples, 0.95),
		maxMs = samples[#samples] or 0,
	}
end

-- Clears rolling heartbeat samples so steady-state percentiles are not
-- polluted by setup bursts (populate) or the first synchronized click wave.
local function resetHeartbeatSamples(run, reason)
	local cleared = #run.heartbeatSamples
	table.clear(run.heartbeatSamples)
	print(string.format(
		"[PlotStressTest] Heartbeat samples reset (%s); cleared %d samples",
		tostring(reason),
		cleared
	))
end

local function liveStressFeedCount(run)
	local count = 0
	for _, feed in ipairs(run.feeds) do
		if feed.Parent then
			count += 1
		end
	end
	return count
end

local function liveStressPetCount(run)
	local count = 0
	for _, pet in ipairs(run.pets) do
		if pet.Parent then
			count += 1
		end
	end
	return count
end

local function liveGroundPileCount(run)
	local count = 0
	for _, tree in ipairs(run.trees) do
		if tree.Parent then
			for _, descendant in ipairs(tree:GetDescendants()) do
				if descendant:GetAttribute(State.TreeClicker.GroundPile) == true then
					count += 1
				end
			end
		end
	end
	return count
end

local function recordMetrics(run, reason)
	local stats = heartbeatStats(run)
	local elapsedSeconds = math.round((os.clock() - run.startedAt) * 10) / 10
	local feedCount = liveStressFeedCount(run)
	local petCount = liveStressPetCount(run)
	local treeCount = #run.trees
	local groundPileCount = liveGroundPileCount(run)
	local p50Ms = math.round(stats.p50Ms * 100) / 100
	local p95Ms = math.round(stats.p95Ms * 100) / 100
	local maxMs = math.round(stats.maxMs * 100) / 100
	TelemetryService.Record("plot_stress_metrics", {
		runId = run.id,
		reason = reason,
		elapsedSeconds = elapsedSeconds,
		plots = #run.plots,
		feeds = feedCount,
		pets = petCount,
		trees = treeCount,
		groundPiles = groundPileCount,
		luaHeapKb = math.round(collectgarbage("count")),
		heartbeatP50Ms = p50Ms,
		heartbeatP95Ms = p95Ms,
		heartbeatMaxMs = maxMs,
		treeClickAttempts = run.counters.treeClickAttempts,
		treeClickSuccesses = run.counters.treeClickSuccesses,
		treePickupAttempts = run.counters.treePickupAttempts,
		treePickupSuccesses = run.counters.treePickupSuccesses,
		warnings = run.counters.warnings,
		errors = run.counters.errors,
	})
	print(string.format(
		"[PlotStressTestHeartbeat] reason=%s elapsed=%.1fs plots=%d pets=%d feeds=%d trees=%d groundPiles=%d p50=%.2fms p95=%.2fms max=%.2fms warnings=%d errors=%d",
		tostring(reason),
		elapsedSeconds,
		#run.plots,
		petCount,
		feedCount,
		treeCount,
		groundPileCount,
		p50Ms,
		p95Ms,
		maxMs,
		run.counters.warnings,
		run.counters.errors
	))
end

local function collectTreeGround(run, owner, tree)
	for _, descendant in ipairs(tree:GetDescendants()) do
		if descendant:GetAttribute(State.TreeClicker.GroundPile) == true then
			run.counters.treePickupAttempts += 1
			local ok = FeedMachines.PickupTreeGround(descendant, owner)
			if ok then
				run.counters.treePickupSuccesses += 1
				tagNewOwnerTools(run, owner)
			end
		end
	end
end

local function stressTreesForPlot(plot)
	local trees = {}
	for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
		if feed:GetAttribute(RUN_ID_ATTR) ~= nil
			and feed:GetAttribute(State.Feed.Class) == "Tree" then
			trees[#trees + 1] = feed
		end
	end
	return trees
end

-- Without jitter every tree loop starts in the same burst and waits the same
-- interval, so all 240 trees click on the same frames; the random start offset
-- desynchronizes the loops and the per-wait jitter keeps them from re-locking.
local CLICK_JITTER_FRACTION = 0.3
local clickJitterRng = Random.new()

local function jitteredClickWait(interval)
	task.wait(interval * (1 + (clickJitterRng:NextNumber() * 2 - 1) * CLICK_JITTER_FRACTION))
end

local function treeActivityLoop(run, owner, config, tree)
	task.wait(clickJitterRng:NextNumber() * config.TreeClickIntervalSeconds)
	while activeRun == run and run.stopRequested ~= true do
		if tree.Parent then
			run.counters.treeClickAttempts += 1
			local clicked = FeedMachines.StressClickTree(tree, owner)
			if clicked then
				run.counters.treeClickSuccesses += 1
			end
			collectTreeGround(run, owner, tree)
		end
		jitteredClickWait(config.TreeClickIntervalSeconds)
	end
end

local function treeClickOnlyLoop(clickRun, metricsRun, owner, config, tree)
	task.wait(clickJitterRng:NextNumber() * config.TreeClickIntervalSeconds)
	while clickRun.active == true and tree.Parent and owner.Parent do
		metricsRun.counters.treeClickAttempts += 1
		local clicked = FeedMachines.StressClickTree(tree, owner)
		if clicked then
			metricsRun.counters.treeClickSuccesses += 1
		end
		jitteredClickWait(config.TreeClickIntervalSeconds)
	end
end

local function stopClientTreeClicks(player)
	local key = userKey(player)
	local clickRun = key and clientTreeClickRunsByUserId[key]
	if not clickRun then
		return false, "not-running"
	end
	clickRun.active = false
	clientTreeClickRunsByUserId[key] = nil
	return true
end

local function metricsLoop(run, config)
	while activeRun == run and run.stopRequested ~= true do
		task.wait(config.MetricsIntervalSeconds)
		if activeRun == run and run.stopRequested ~= true then
			recordMetrics(run, "interval")
		end
	end
end

local function realisticMetricsLoop(run, config)
	while clientSession == run and run.stopRequested ~= true do
		task.wait(config.MetricsIntervalSeconds)
		if clientSession ~= run or run.stopRequested == true then
			break
		end
		recordMetrics(run, "realistic-interval")
		if os.clock() >= clientSessionExpiresAt then
			break
		end
	end

	if clientSession == run then
		run.stopRequested = true
		disconnectAll(run.connections)
		recordMetrics(run, "realistic-duration")
		dumpCapturedMessages(run)
		emit("plot_stress_realistic_metrics_stopped", {
			runId = run.id,
			elapsedSeconds = math.round((os.clock() - run.startedAt) * 10) / 10,
			plots = #run.plots,
			pets = liveStressPetCount(run),
			feeds = liveStressFeedCount(run),
			trees = #run.trees,
		})
		clientSession = nil
	end
end

local function ensureRealisticSession(config)
	if clientSession and clientSession.stopRequested ~= true then
		clientSessionExpiresAt = math.max(clientSessionExpiresAt, os.clock() + config.DurationSeconds)
		return clientSession
	end

	local run = newRun(config)
	clientSession = run
	clientSessionExpiresAt = os.clock() + config.DurationSeconds
	run.connections[#run.connections + 1] = RuntimeGuard.Connect(RunService.Heartbeat, "PlotStressTest.RealisticHeartbeat", function(dt)
		run.heartbeatSamples[#run.heartbeatSamples + 1] = dt * 1000
		if #run.heartbeatSamples > 1200 then
			table.remove(run.heartbeatSamples, 1)
		end
	end)
	run.connections[#run.connections + 1] = RuntimeGuard.Connect(LogService.MessageOut, "PlotStressTest.RealisticMessageOut", function(message, messageType)
		recordLogMessage(run, message, messageType)
	end)
	RuntimeGuard.Spawn("PlotStressTest.RealisticMetricsLoop", realisticMetricsLoop, run, config)
	return run
end

local function runScenario(run, config)
	local owner, ownerPlot = waitForOwner(config)
	if not owner then
		warn("[PlotStressTest] No player-owned plot became available; stress run aborted")
		PlotStressTest.Stop("no-owner")
		return
	end

	PlotStressTest.DisableTutorialFor(owner)
	rememberOwnerTools(run, owner)
	run.ownerPlot = ownerPlot

	local plots = choosePlots(ownerPlot, config.PlotCount)
	if #plots == 0 then
		warn("[PlotStressTest] No runtime plots found; stress run aborted")
		PlotStressTest.Stop("no-plots")
		return
	end

	local setupStart = os.clock()
	for _, plot in ipairs(plots) do
		RuntimeGuard.Run("PlotStressTest.PreparePlot." .. plot.Name, preparePlot, run, plot, owner, ownerPlot, config)
	end
	run.counters.setupSeconds = os.clock() - setupStart

	emit("plot_stress_started", {
		runId = run.id,
		ownerUserId = owner.UserId,
		plots = #run.plots,
		pets = run.counters.petsCreated,
		patches = run.counters.patchesCreated,
		trees = run.counters.treesCreated,
		setupSeconds = math.round(run.counters.setupSeconds * 100) / 100,
	})
	recordMetrics(run, "post-setup")
	resetHeartbeatSamples(run, "post-setup")

	if config.ActiveCollection then
		for index, tree in ipairs(run.trees) do
			RuntimeGuard.Spawn("PlotStressTest.TreeActivity." .. tostring(index), treeActivityLoop, run, owner, config, tree)
		end
	end
	RuntimeGuard.Spawn("PlotStressTest.MetricsLoop", metricsLoop, run, config)

	task.wait(config.DurationSeconds)
	if activeRun == run then
		PlotStressTest.Stop("duration")
	end
end

local function clearPlayerPlot(player)
	stopClientTreeClicks(player)
	local plot = PlotService.GetPlayerPlot(player)
	if not plot then
		return false, "no-plot"
	end
	destroyStressPetsOn(plot)
	destroyStressFeedsOn(plot)
	local profile = PlayerDataService.GetProfile(player)
	if profile then
		PlotGridService.ApplyProfileState(plot, profile)
	else
		PlotGridService.ResetPlotState(plot)
	end
	return true
end

local function startClientTreeClicks(player, overrides)
	if not RunService:IsStudio() then
		return false, "not-studio"
	end

	local plot = PlotService.GetPlayerPlot(player)
	if not plot then
		return false, "no-plot"
	end

	local trees = stressTreesForPlot(plot)
	if #trees == 0 then
		return false, "no-stress-trees"
	end

	stopClientTreeClicks(player)

	local config = readConfig(overrides)
	config.PlotCount = 1
	config.ActiveCollection = false
	local run = ensureRealisticSession(config)
	addUnique(run.plots, plot)
	for _, tree in ipairs(trees) do
		addUnique(run.trees, tree)
	end

	local key = userKey(player)
	local clickRun = {
		active = true,
		runId = run.id,
		treeCount = #trees,
	}
	clientTreeClickRunsByUserId[key] = clickRun

	for index, tree in ipairs(trees) do
		RuntimeGuard.Spawn("PlotStressTest.ClientTreeClick." .. tostring(player.UserId) .. "." .. tostring(index), treeClickOnlyLoop, clickRun, run, player, config, tree)
	end

	emit("plot_stress_player_tree_clicks_started", {
		runId = run.id,
		userId = player.UserId,
		plot = plot.Name,
		trees = #trees,
	})
	return true, run.id
end

local populateLocksByUserId = {}

local function populatePlayerPlot(player, overrides)
	if not RunService:IsStudio() then
		return false, "not-studio"
	end

	local plot = PlotService.GetPlayerPlot(player)
	if not plot then
		return false, "no-plot"
	end

	-- preparePlot now yields during placement, so a double-fired populate
	-- could interleave destroy/create on the same plot without this lock.
	local key = userKey(player)
	if populateLocksByUserId[key] then
		return false, "populate-in-progress"
	end
	populateLocksByUserId[key] = true

	local config = readConfig(overrides)
	config.PlotCount = 1
	config.ActiveCollection = false

	PlotStressTest.DisableTutorialFor(player)
	local run = ensureRealisticSession(config)
	rememberOwnerTools(run, player)
	run.ownerPlot = plot

	local setupStart = os.clock()
	local runOk, prepared = RuntimeGuard.Run("PlotStressTest.PrepareOwnPlot." .. tostring(player.UserId), preparePlot, run, plot, player, plot, config)
	run.counters.setupSeconds = os.clock() - setupStart
	populateLocksByUserId[key] = nil
	recordMetrics(run, "client-populate")
	resetHeartbeatSamples(run, "post-populate")

	if runOk ~= true or prepared ~= true then
		cleanupTools(run)
		return false, "prepare-failed"
	end

	emit("plot_stress_player_populated", {
		runId = run.id,
		userId = player.UserId,
		plot = plot.Name,
		pets = run.counters.petsCreated,
		patches = run.counters.patchesCreated,
		trees = run.counters.treesCreated,
		setupSeconds = math.round(run.counters.setupSeconds * 100) / 100,
	})
	return true, run.id
end

local function ensureClientRemote()
	local remote = ReplicatedStorage:FindFirstChild(CLIENT_REMOTE_NAME)
	if remote and not remote:IsA("RemoteEvent") then
		remote:Destroy()
		remote = nil
	end
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = CLIENT_REMOTE_NAME
		remote.Parent = ReplicatedStorage
	end
	clientRemote = remote
	return remote
end

local function normalizeClientAction(action)
	if type(action) ~= "string" or action == "" then
		return "populate"
	end
	return string.lower(action)
end

local function handleClientCommand(player, action, overrides)
	local normalized = normalizeClientAction(action)
	if normalized == "populate" or normalized == "start" then
		local ok, code = populatePlayerPlot(player, type(overrides) == "table" and overrides or nil)
		if not ok then
			warn(string.format("[PlotStressTest] Client populate failed for %d: %s", player.UserId, tostring(code)))
		end
		return
	end
	if normalized == "clicktrees" or normalized == "autoclicktrees" then
		local ok, code = startClientTreeClicks(player, type(overrides) == "table" and overrides or nil)
		if not ok then
			warn(string.format("[PlotStressTest] Client tree clicks failed for %d: %s", player.UserId, tostring(code)))
		end
		return
	end
	if normalized == "stopclicktrees" then
		stopClientTreeClicks(player)
		return
	end
	if normalized == "resetheartbeat" then
		PlotStressTest.ResetHeartbeatSamples("client-command")
		return
	end
	if normalized == "clear" or normalized == "stop" then
		local ok, code = clearPlayerPlot(player)
		if not ok then
			warn(string.format("[PlotStressTest] Client clear failed for %d: %s", player.UserId, tostring(code)))
		end
		return
	end
	warn(string.format("[PlotStressTest] Unknown client command from %d: %s", player.UserId, tostring(action)))
end

-- Manual reset for separating warmup from steady state, e.g. after the first
-- synchronized tree-drop wave. Applies to whichever runs are live.
function PlotStressTest.ResetHeartbeatSamples(reason)
	local resetCount = 0
	if activeRun then
		resetHeartbeatSamples(activeRun, reason or "manual")
		resetCount += 1
	end
	if clientSession and clientSession ~= activeRun then
		resetHeartbeatSamples(clientSession, reason or "manual")
		resetCount += 1
	end
	return resetCount > 0
end

function PlotStressTest.IsEnabled()
	return RunService:IsStudio() and SERVER_FOLDER:GetAttribute(ATTR_ENABLED) == true
end

function PlotStressTest.ShouldDisableTutorial()
	return PlotStressTest.IsEnabled() and booleanAttr(ATTR_DISABLE_TUTORIAL, DEFAULT_CONFIG.DisableTutorial) == true
end

function PlotStressTest.PreparePlayerProfile(_player, profile)
	if not PlotStressTest.ShouldDisableTutorial() then
		return false
	end
	if not (profile and profile.Data) then
		return false
	end
	profile.Data.Onboarding = Onboarding.CompleteState()
	return true
end

function PlotStressTest.DisableTutorialFor(player)
	if not RunService:IsStudio() or booleanAttr(ATTR_DISABLE_TUTORIAL, DEFAULT_CONFIG.DisableTutorial) ~= true then
		return false
	end
	local profile = PlayerDataService.GetProfile(player)
	if not (profile and profile.Data) then
		return false
	end
	profile.Data.Onboarding = Onboarding.CompleteState()
	PlayerReplicaService.PublishOnboarding(player, profile)
	return true
end

function PlotStressTest.PopulateAllPlayers(overrides)
	if not RunService:IsStudio() then
		return false, "not-studio"
	end

	local populated = 0
	local failed = 0
	for _, player in ipairs(Players:GetPlayers()) do
		local ok, code = populatePlayerPlot(player, type(overrides) == "table" and overrides or nil)
		if ok then
			populated += 1
		else
			failed += 1
			warn(string.format("[PlotStressTest] PopulateAllPlayers failed for %d: %s", player.UserId, tostring(code)))
		end
	end

	emit("plot_stress_populate_all_players", {
		populated = populated,
		failed = failed,
	})
	return true, populated, failed
end

function PlotStressTest.ClearAllPlayers()
	if not RunService:IsStudio() then
		return false, "not-studio"
	end

	local cleared = 0
	local failed = 0
	for _, player in ipairs(Players:GetPlayers()) do
		local ok, code = clearPlayerPlot(player)
		if ok then
			cleared += 1
		else
			failed += 1
			warn(string.format("[PlotStressTest] ClearAllPlayers failed for %d: %s", player.UserId, tostring(code)))
		end
	end

	emit("plot_stress_clear_all_players", {
		cleared = cleared,
		failed = failed,
	})
	return true, cleared, failed
end

function PlotStressTest.ClickTreesAllPlayers(overrides)
	if not RunService:IsStudio() then
		return false, "not-studio"
	end

	local started = 0
	local failed = 0
	for _, player in ipairs(Players:GetPlayers()) do
		local ok, code = startClientTreeClicks(player, type(overrides) == "table" and overrides or nil)
		if ok then
			started += 1
		else
			failed += 1
			warn(string.format("[PlotStressTest] ClickTreesAllPlayers failed for %d: %s", player.UserId, tostring(code)))
		end
	end

	emit("plot_stress_click_trees_all_players", {
		started = started,
		failed = failed,
	})
	return true, started, failed
end

function PlotStressTest.StopClickTreesAllPlayers()
	if not RunService:IsStudio() then
		return false, "not-studio"
	end

	local stopped = 0
	for _, player in ipairs(Players:GetPlayers()) do
		local ok = stopClientTreeClicks(player)
		if ok then
			stopped += 1
		end
	end

	emit("plot_stress_stop_click_trees_all_players", {
		stopped = stopped,
	})
	return true, stopped
end

function PlotStressTest.Start(overrides)
	if not PlotStressTest.IsEnabled() then
		return false, "disabled"
	end
	if activeRun then
		return false, "already-running"
	end

	local config = readConfig(overrides)
	local run = newRun(config)
	activeRun = run

	run.connections[#run.connections + 1] = RuntimeGuard.Connect(RunService.Heartbeat, "PlotStressTest.Heartbeat", function(dt)
		run.heartbeatSamples[#run.heartbeatSamples + 1] = dt * 1000
		if #run.heartbeatSamples > 1200 then
			table.remove(run.heartbeatSamples, 1)
		end
	end)
	run.connections[#run.connections + 1] = RuntimeGuard.Connect(LogService.MessageOut, "PlotStressTest.MessageOut", function(message, messageType)
		recordLogMessage(run, message, messageType)
	end)

	RuntimeGuard.Spawn("PlotStressTest.RunScenario", runScenario, run, config)
	return true, run.id
end

function PlotStressTest.Stop(reason)
	local run = activeRun
	if not run then
		return false, "not-running"
	end

	activeRun = nil
	run.stopRequested = true
	disconnectAll(run.connections)

	recordMetrics(run, reason or "stopped")
	dumpCapturedMessages(run)
	for _, plot in ipairs(run.plots) do
		RuntimeGuard.Run("PlotStressTest.ResetPlot." .. plot.Name, resetPlotAfterRun, plot, run.ownerPlot)
	end
	cleanupTools(run)

	emit("plot_stress_stopped", {
		runId = run.id,
		reason = reason or "stopped",
		elapsedSeconds = math.round((os.clock() - run.startedAt) * 10) / 10,
		plots = #run.plots,
		petsCreated = run.counters.petsCreated,
		patchesCreated = run.counters.patchesCreated,
		treesCreated = run.counters.treesCreated,
		treeClickAttempts = run.counters.treeClickAttempts,
		treeClickSuccesses = run.counters.treeClickSuccesses,
		treePickupAttempts = run.counters.treePickupAttempts,
		treePickupSuccesses = run.counters.treePickupSuccesses,
	})
	return true
end

function PlotStressTest.Watch(overrides)
	if not RunService:IsStudio() then
		return false, "not-studio"
	end
	local remote = ensureClientRemote()
	if not clientRemoteConnection then
		clientRemoteConnection = RuntimeGuard.Connect(remote.OnServerEvent, "PlotStressTest.ClientCommand", handleClientCommand)
	end
	if not playerRemovingConnection then
		playerRemovingConnection = RuntimeGuard.Connect(Players.PlayerRemoving, "PlotStressTest.PlayerRemoving", function(player)
			stopClientTreeClicks(player)
		end)
	end
	if watchConnection then
		return true
	end

	watchConnection = RuntimeGuard.Connect(SERVER_FOLDER:GetAttributeChangedSignal(ATTR_ENABLED), "PlotStressTest.EnabledChanged", function()
		if PlotStressTest.IsEnabled() then
			PlotStressTest.Start(overrides)
		else
			PlotStressTest.Stop("disabled")
		end
	end)
	if PlotStressTest.IsEnabled() then
		PlotStressTest.Start(overrides)
	end
	return true
end

return PlotStressTest
