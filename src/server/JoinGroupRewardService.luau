local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Server = script.Parent
local NotificationService = require(Server:WaitForChild("NotificationService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local SeedTools = require(Server:WaitForChild("SeedTools"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GroupReward = require(Shared:WaitForChild("GroupReward"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local JoinGroupRewardService = {}

local PROMPT_NAME = "JoinGroupRewardPrompt"
local REQUEST_RATE_SECONDS = 0.5

local started = false
local locks = {}
local lastRequestAt = {}
-- [UserId] = true between "we asked this client to open the join modal" and the
-- one collect retry that answer is allowed to buy. Without it a client could
-- spam the retry remote and, through it, this server's GroupService web budget.
local joinPromptPending = {}
local promptRemote = nil

local function userKey(player)
	return player and player.UserId or nil
end

local function int(value)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.max(math.floor(value), 0)
end

local function rootPart(player)
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root or nil
end

local function rewardModel()
	local model = Workspace:FindFirstChild(GroupReward.ModelName)
	return model and model:IsA("Model") and model or nil
end

local function promptPart()
	local model = rewardModel()
	local part = model and model:FindFirstChild(GroupReward.TouchPartName)
	return part and part:IsA("BasePart") and part or nil
end

local function configurePrompt(prompt)
	local config = GroupReward.Prompt or {}
	prompt.Name = PROMPT_NAME
	prompt.ActionText = type(config.ActionText) == "string" and config.ActionText or "Collect"
	prompt.ObjectText = type(config.ObjectText) == "string" and config.ObjectText or ""
	prompt.MaxActivationDistance = tonumber(config.MaxActivationDistance) or 10
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	prompt.Style = Enum.ProximityPromptStyle.Custom
	if prompt:GetAttribute("Theme") == nil then
		prompt:SetAttribute("Theme", "Default")
	end
end

local function ensurePrompt(part)
	local prompt = part:FindFirstChild(PROMPT_NAME)
	if prompt and not prompt:IsA("ProximityPrompt") then
		warn(string.format("[JoinGroupRewardService] %s is %s, expected ProximityPrompt", prompt:GetFullName(), prompt.ClassName))
		return nil
	end
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Parent = part
	end
	configurePrompt(prompt)
	return prompt
end

local function prepareDisplayModel()
	local model = rewardModel()
	if not model then
		return
	end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name ~= GroupReward.TouchPartName then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
		end
	end
end

local function takeRateLimit(player)
	local key = userKey(player)
	if not key then
		return false
	end
	local now = os.clock()
	if now - (lastRequestAt[key] or 0) < REQUEST_RATE_SECONDS then
		return false
	end
	lastRequestAt[key] = now
	return true
end

local function isNearPrompt(player, part)
	local root = rootPart(player)
	if not (root and part) then
		return false
	end
	local maxDistance = tonumber((GroupReward.Prompt or {}).MaxActivationDistance) or 10
	return (root.Position - part.Position).Magnitude <= maxDistance + 3
end

local function isGroupMember(player)
	local groupId = int(GroupReward.GroupId)
	if groupId <= 0 then
		return false
	end
	local ok, result = pcall(function()
		return player:IsInGroup(groupId)
	end)
	if not ok then
		warn("[JoinGroupRewardService] IsInGroup failed for user " .. tostring(userKey(player)) .. ": " .. tostring(result))
		return false
	end
	return result == true
end

-- Player:IsInGroup answers from a per-server cache, so someone who joins through
-- the native modal still reads as a non-member here for up to a minute after.
-- GetGroupsAsync asks the web endpoint instead, which is what makes the collect
-- retry that follows a successful join land immediately. It yields and costs a
-- request, so only the retry path pays for it, and only once per prompt.
local function isGroupMemberUncached(player)
	local groupId = int(GroupReward.GroupId)
	if groupId <= 0 then
		return false
	end
	local ok, groups = pcall(function()
		return GroupService:GetGroupsAsync(player.UserId)
	end)
	if not ok then
		warn("[JoinGroupRewardService] GetGroupsAsync failed for user " .. tostring(userKey(player)) .. ": " .. tostring(groups))
		return false
	end
	if type(groups) ~= "table" then
		return false
	end
	for _, info in ipairs(groups) do
		if type(info) == "table" and int(info.Id) == groupId then
			return true
		end
	end
	return false
end

local function requestJoinPrompt(player)
	local key = userKey(player)
	if not (promptRemote and key) then
		NotificationService.Error(player, GroupReward.NotInGroupMessage)
		return
	end
	joinPromptPending[key] = true
	promptRemote:FireClient(player)
end

local function saveProfile(profile)
	local ok = pcall(function()
		profile:Save()
	end)
	return ok
end

local function rollbackPrepared(profile, prepared)
	if type(prepared) ~= "table" then
		return
	end
	local seedId = prepared.seedId
	local amount = int(prepared.amount)
	local inventory = profile and profile.Data and profile.Data.SeedInventory
	if type(seedId) == "string" and amount > 0 and type(inventory) == "table" then
		inventory[seedId] = math.max(int(inventory[seedId]) - amount, 0)
		if inventory[seedId] <= 0 then
			inventory[seedId] = nil
		end
	end
	SeedTools.DestroyPrepared(prepared)
end

local function prepareReward()
	local reward = GroupReward.Reward or {}
	if reward.Type ~= GroupReward.RewardTypes.Seed then
		return nil, "unsupported-reward"
	end
	return SeedTools.PrepareGrant(reward.Id, reward.Quantity)
end

local function grantReward(player, profile)
	local prepared, code = prepareReward()
	if not prepared then
		return false, code or "grant-failed", nil
	end
	local granted, grantCode = SeedTools.ApplyPrepared(player, profile, prepared)
	if not granted then
		return false, grantCode or "grant-failed", nil
	end
	return true, "ok", prepared
end

local function collect(player, part, options)
	options = type(options) == "table" and options or {}
	if not takeRateLimit(player) then
		return
	end
	if not isNearPrompt(player, part) then
		return
	end

	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		NotificationService.Error(player, "Could not collect reward yet")
		return
	end
	if profile.Data.JoinGroupRewardCollected == true then
		PlayerReplicaService.PublishJoinGroupRewardCollected(player, profile)
		return
	end
	if not isGroupMember(player) then
		if options.verifyUncached ~= true or not isGroupMemberUncached(player) then
			if options.promptJoin == true then
				requestJoinPrompt(player)
			else
				NotificationService.Error(player, GroupReward.NotInGroupMessage)
			end
			return
		end
		-- The uncached lookup yielded; re-establish everything it could have
		-- outlived before granting anything.
		if player.Parent == nil then
			return
		end
		profile = PlayerDataService.GetProfile(player)
		if not profile or profile.Data.JoinGroupRewardCollected == true then
			return
		end
		if not isNearPrompt(player, part) then
			return
		end
	end

	local key = userKey(player)
	if not key or locks[key] then
		return
	end

	locks[key] = true
	local wasCollected = profile.Data.JoinGroupRewardCollected == true
	local prepared = nil
	local granted = false
	local resultCode = "server-error"

	local ok, err = pcall(function()
		granted, resultCode, prepared = grantReward(player, profile)
		if not granted then
			return
		end

		profile.Data.JoinGroupRewardCollected = true
		resultCode = "save-failed"
		if not saveProfile(profile) then
			profile.Data.JoinGroupRewardCollected = wasCollected
			rollbackPrepared(profile, prepared)
			granted = false
			return
		end
		resultCode = "ok"
	end)

	locks[key] = nil

	if not ok then
		warn("[JoinGroupRewardService] Reward grant failed: " .. tostring(err))
		profile.Data.JoinGroupRewardCollected = wasCollected
		if granted and prepared then
			rollbackPrepared(profile, prepared)
			granted = false
		end
		resultCode = "server-error"
	end

	PlayerReplicaService.PublishInventories(player, profile)
	PlayerReplicaService.PublishJoinGroupRewardCollected(player, profile)

	if resultCode == "ok" then
		NotificationService.Success(player, GroupReward.SuccessMessage)
	elseif resultCode == "inventory-full" then
		-- ToolGrantService already sends the inventory cap notification.
	elseif resultCode == "no-backpack" then
		NotificationService.Error(player, "Could not collect reward yet. Please rejoin and try again")
	else
		NotificationService.Error(player, "Could not collect reward yet")
		warn("[JoinGroupRewardService] Reward grant failed: " .. tostring(resultCode))
	end
end

function JoinGroupRewardService.Start()
	if started then
		return
	end
	started = true

	prepareDisplayModel()

	local part = promptPart()
	if not part then
		warn("[JoinGroupRewardService] Missing Workspace." .. GroupReward.ModelName .. "." .. GroupReward.TouchPartName)
		return
	end
	local prompt = ensurePrompt(part)
	if not prompt then
		return
	end

	promptRemote = Remotes.get(Remotes.Names.JoinGroupPrompt)

	RuntimeGuard.Connect(prompt.Triggered, "JoinGroupRewardService.Triggered", function(player)
		collect(player, part, { promptJoin = true })
	end)
	-- The client answers the join modal here. One retry per prompt we asked for,
	-- and it re-verifies membership server-side rather than trusting the report.
	RuntimeGuard.Connect(Remotes.get(Remotes.Names.JoinGroupRewardRequest).OnServerEvent, "JoinGroupRewardService.JoinedRequest", function(player)
		local key = userKey(player)
		if not (key and joinPromptPending[key]) then
			return
		end
		joinPromptPending[key] = nil
		collect(player, part, { verifyUncached = true })
	end)
	RuntimeGuard.Connect(Players.PlayerRemoving, "JoinGroupRewardService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			locks[key] = nil
			lastRequestAt[key] = nil
			joinPromptPending[key] = nil
		end
	end)
end

return JoinGroupRewardService
