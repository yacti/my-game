local ReplicatedStorage = game:GetService("ReplicatedStorage")

local replicaShared = ReplicatedStorage:WaitForChild("ReplicaShared", 10)
assert(replicaShared and replicaShared:IsA("Folder"), "Missing ReplicatedStorage.ReplicaShared Folder")
local Replica = require(ReplicatedStorage:WaitForChild("ReplicaClient"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerState = require(Shared:WaitForChild("PlayerState"))

local PlayerStateStore = {}

local started = false
local replica = nil
local listeners = {}
local currentData = {}

local function listenerBucket(fieldName)
	local bucket = listeners[fieldName]
	if not bucket then
		bucket = {}
		listeners[fieldName] = bucket
	end
	return bucket
end

local function notify(fieldName, newValue, oldValue)
	local bucket = listeners[fieldName]
	if not bucket then
		return
	end
	for callback in pairs(bucket) do
		task.spawn(callback, newValue, oldValue)
	end
end

local function bindReplica(nextReplica)
	replica = nextReplica
	currentData = nextReplica.Data or {}

	for _, fieldName in pairs(PlayerState.Fields) do
		notify(fieldName, currentData[fieldName], nil)
		nextReplica:OnSet({ fieldName }, function(newValue, oldValue)
			currentData[fieldName] = newValue
			notify(fieldName, newValue, oldValue)
		end)
	end

	nextReplica.Maid:Add(function()
		if replica == nextReplica then
			local previousData = currentData
			replica = nil
			currentData = {}
			for _, fieldName in pairs(PlayerState.Fields) do
				notify(fieldName, nil, previousData[fieldName])
			end
		end
	end)
end

function PlayerStateStore.start()
	if started then
		return
	end
	started = true

	Replica.OnNew(PlayerState.Token, bindReplica)
end

function PlayerStateStore.Get(fieldName)
	return currentData[fieldName]
end

function PlayerStateStore.GetState()
	local copy = {}
	for key, value in pairs(currentData) do
		copy[key] = value
	end
	return copy
end

function PlayerStateStore.Observe(fieldName, callback)
	local bucket = listenerBucket(fieldName)
	bucket[callback] = true

	if currentData[fieldName] ~= nil then
		task.spawn(callback, currentData[fieldName], nil)
	end

	local connection = {}
	function connection:Disconnect()
		bucket[callback] = nil
	end
	return connection
end

PlayerStateStore.Fields = PlayerState.Fields

return PlayerStateStore
