-- Renders the two global leaderboards on Workspace.Leaderboard.
--
-- Two independent halves, deliberately:
--
--   The ranked list is identical for everyone, so the server sends one snapshot
--   over LeaderboardSync and every client builds the rows locally. Building
--   client-side keeps ~700 instances per refresh out of replication; the payload
--   is a few KB every 30s instead.
--
--   YourStat is per-player, and it reads the local replica rather than the
--   snapshot, so your own number updates the instant your cash or roll count
--   changes instead of waiting for the next refresh. Because the SurfaceGui
--   lives in Workspace, writing to it from here is client-local -- every player
--   sees their own value on the same instance. The server must never touch
--   those two labels.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Leaderboards = require(Shared:WaitForChild("Leaderboards"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))

local LeaderboardController = {}

local WAIT_SECONDS = 20
local ROW_NAME = "LeaderboardRow"

local syncRemote = Remotes.get(Remotes.Names.LeaderboardSync)
local syncRequestRemote = Remotes.get(Remotes.Names.LeaderboardSyncRequest)

local started = false
local boards = {} -- [boardId] = { board, frame, templates, yourLabel, scoreLabel }
local payloads = {} -- [boardId] = last payload received, replayed when a board binds late

local function formatScore(value)
	return NumberFormatter.Integer(value)
end

-- Boards live under a Persistent model, but a bind that runs before streaming
-- has delivered it must not kill the controller.
local function findBoardParts(model)
	local gui, yourStat
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("SurfaceGui") then
			if descendant.Name == "LeaderboardGui" then
				gui = descendant
			elseif descendant.Name == "YourStat" then
				yourStat = descendant
			end
		end
	end
	return gui, yourStat
end

local function resolveUDim(udim, basis)
	return udim.Scale * basis + udim.Offset
end

-- AutomaticCanvasSize cannot measure children whose height is in Scale, and
-- every row template is (0.86, 0.07/0.09) with SizeConstraint RelativeXX. Left
-- on Automatic, a 100-row board reported a 3406px canvas over 5615px of real
-- content -- the bottom ~40 places simply could not be scrolled to. So the
-- canvas is driven explicitly off the layout's measured content instead.
local function syncCanvas(record)
	local layout = record.layout
	local frame = record.frame
	if not (layout and frame and frame.Parent) then
		return
	end
	local extra = 0
	if record.padding then
		local basis = frame.AbsoluteSize.Y
		extra = resolveUDim(record.padding.PaddingTop, basis) + resolveUDim(record.padding.PaddingBottom, basis)
	end
	frame.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y + extra)
end

local function clearRows(record)
	for _, child in ipairs(record.frame:GetChildren()) do
		if child.Name == ROW_NAME then
			child:Destroy()
		end
	end
	record.rows = {}
end

local function buildRow(record, rank)
	local template = record.templates[Leaderboards.TemplateNameForRank(rank)]
	if not template then
		return nil
	end

	local row = template:Clone()
	row.Name = ROW_NAME
	row.LayoutOrder = rank
	row.Visible = true

	local placement = row:FindFirstChild("Placement")
	local built = {
		frame = row,
		rankLabel = placement and placement:FindFirstChild("RankLabel"),
		nameLabel = row:FindFirstChild("NameLabel"),
		valueLabel = row:FindFirstChild("ValueLabel"),
		image = row:FindFirstChild("PlayerImageLabel"),
	}
	if built.rankLabel then
		built.rankLabel.Text = tostring(rank)
	end
	row.Parent = record.frame
	return built
end

local function applyEntry(row, entry)
	if row.nameLabel then
		row.nameLabel.Text = tostring(entry.n or "Player")
	end
	if row.valueLabel then
		row.valueLabel.Text = formatScore(entry.v)
	end
	if row.image then
		-- Replaces the retired roblox.com/headshot-thumbnail URL the templates
		-- ship with; rbxthumb is resolved by the engine, so a full board costs
		-- no web calls and cannot be rate limited.
		local image = Leaderboards.HeadshotFor(entry.u)
		if row.image.Image ~= image then
			row.image.Image = image
		end
	end
end

-- Rows are reused across refreshes rather than rebuilt. A full board is ~700
-- instances; destroying and recreating that every 30s on every client is a
-- visible hitch on low-end mobile, and the ranking rarely changes shape -- only
-- the text in each row does. Rows are only created or destroyed when the entry
-- count actually changes.
local function render(record, payload)
	if not (record.frame and record.frame.Parent) then
		return
	end
	if not (payload and type(payload.entries) == "table") then
		clearRows(record)
		return
	end

	local entries = payload.entries
	local limit = math.min(#entries, Leaderboards.MaxEntries)

	for rank = 1, limit do
		local entry = entries[rank]
		if type(entry) == "table" then
			local row = record.rows[rank]
			if not (row and row.frame.Parent) then
				row = buildRow(record, rank)
				record.rows[rank] = row
			end
			if row then
				applyEntry(row, entry)
			end
		end
	end

	for rank = limit + 1, #record.rows do
		local row = record.rows[rank]
		if row then
			row.frame:Destroy()
			record.rows[rank] = nil
		end
	end

	syncCanvas(record)
end

local function bindYourStat(record, yourStat)
	local label = yourStat:FindFirstChild("Label")
	local scoreLabel = yourStat:FindFirstChild("LocalScoreLabel")
	if label then
		label.Text = record.board.YourLabel
	end
	if not scoreLabel then
		return
	end
	record.scoreLabel = scoreLabel
	-- Placeholder art ships with a value baked in; blank it until the replica
	-- arrives so nobody sees someone else's mock number as their own.
	scoreLabel.Text = formatScore(0)

	PlayerStateStore.Observe(record.board.ReplicaField, function(value)
		if record.scoreLabel and record.scoreLabel.Parent then
			record.scoreLabel.Text = formatScore(value or 0)
		end
	end)
end

local function bindBoard(folder, board)
	local model = folder:WaitForChild(board.ModelName, WAIT_SECONDS)
	if not model then
		warn("[LeaderboardController] Missing Workspace." .. Leaderboards.FolderName .. "." .. board.ModelName)
		return
	end

	local gui, yourStat = findBoardParts(model)
	if not gui then
		warn("[LeaderboardController] " .. board.ModelName .. " has no LeaderboardGui")
		return
	end

	local frame = gui:FindFirstChild("LeaderboardFrame")
	if not frame then
		warn("[LeaderboardController] " .. board.ModelName .. " has no LeaderboardFrame")
		return
	end

	-- Headers come from config so the board text and the stat it ranks can never
	-- drift apart (TopCash reads "RIGHT NOW" because rebirth zeroes the balance).
	local header = gui:FindFirstChild("Header")
	if header then
		header.Text = board.Header
	end
	local subheader = gui:FindFirstChild("Subheader")
	if subheader then
		subheader.Text = board.Subheader
	end

	local templates = {}
	local names = { Leaderboards.RowTemplateName }
	for _, podium in ipairs(Leaderboards.PodiumTemplateNames) do
		names[#names + 1] = podium
	end
	for _, name in ipairs(names) do
		local template = frame:FindFirstChild(name)
		if template then
			template.Visible = false
			templates[name] = template
		else
			warn("[LeaderboardController] " .. board.ModelName .. " missing template " .. name)
		end
	end

	local record = {
		board = board,
		frame = frame,
		templates = templates,
		rows = {},
		layout = frame:FindFirstChild("UIListLayout"),
		padding = frame:FindFirstChild("UIPadding"),
	}
	boards[board.Id] = record

	if record.layout then
		frame.AutomaticCanvasSize = Enum.AutomaticSize.None
		RuntimeGuard.Connect(
			record.layout:GetPropertyChangedSignal("AbsoluteContentSize"),
			"LeaderboardController.ContentResized." .. board.Id,
			function()
				syncCanvas(record)
			end
		)
	else
		warn("[LeaderboardController] " .. board.ModelName .. " LeaderboardFrame has no UIListLayout")
	end

	if yourStat then
		bindYourStat(record, yourStat)
	end

	clearRows(record)
	if payloads[board.Id] then
		render(record, payloads[board.Id])
	end
end

function LeaderboardController.start()
	if started then
		return
	end
	started = true

	-- Payloads are kept even when no board is bound yet, so a snapshot that
	-- lands mid-bind is replayed rather than dropped.
	RuntimeGuard.Connect(syncRemote.OnClientEvent, "LeaderboardController.Sync", function(boardId, payload)
		if type(boardId) ~= "string" or type(payload) ~= "table" then
			return
		end
		payloads[boardId] = payload
		local record = boards[boardId]
		if record then
			render(record, payload)
		end
	end)

	RuntimeGuard.Spawn("LeaderboardController.Bind", function()
		local folder = Workspace:WaitForChild(Leaderboards.FolderName, WAIT_SECONDS)
		if not folder then
			warn("[LeaderboardController] Missing Workspace." .. Leaderboards.FolderName)
			return
		end
		for _, board in ipairs(Leaderboards.Boards) do
			RuntimeGuard.Run("LeaderboardController.Bind." .. board.Id, bindBoard, folder, board)
		end

		-- Ask once the boards exist: a joiner would otherwise stare at an empty
		-- board until the next 30s refresh broadcast.
		RuntimeGuard.Run("LeaderboardController.RequestSync", function()
			syncRequestRemote:FireServer()
		end)
	end)
end

return LeaderboardController
