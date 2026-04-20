local DataStoreService = game:GetService("DataStoreService")

local AUTO_SAVE_INTERVAL = 60

local ProfileService = {}

local ProfileStore = {}
ProfileStore.__index = ProfileStore

local Profile = {}
Profile.__index = Profile

function ProfileService.GetProfileStore(storeName, defaultData)
	local self = setmetatable({}, ProfileStore)
	self._storeName = storeName
	self._defaultData = defaultData
	self._dataStore = DataStoreService:GetDataStore(storeName)
	return self
end

function ProfileStore:LoadProfileAsync(key)
	local savedData
	local ok, err = pcall(function()
		savedData = self._dataStore:GetAsync(key)
	end)

	if not ok then
		warn("ProfileService: Failed to load '" .. key .. "': " .. tostring(err))
		return nil
	end

	local data = {}
	for k, v in pairs(self._defaultData) do
		data[k] = v
	end
	if savedData then
		for k, v in pairs(savedData) do
			data[k] = v
		end
	end

	local profile = setmetatable({}, Profile)
	profile.Data = data
	profile._store = self
	profile._key = key
	profile._released = false

	task.spawn(function()
		while not profile._released do
			task.wait(AUTO_SAVE_INTERVAL)
			if not profile._released then
				profile:_save()
			end
		end
	end)

	return profile
end

function Profile:_save()
	local ok, err = pcall(function()
		self._store._dataStore:SetAsync(self._key, self.Data)
	end)
	if not ok then
		warn("ProfileService: Failed to save '" .. self._key .. "': " .. tostring(err))
	end
end

function Profile:Release()
	if self._released then return end
	self._released = true
	self:_save()
end

return ProfileService
