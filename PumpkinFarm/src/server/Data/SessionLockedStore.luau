--!strict
--[[
	SessionLockedStore
	Path: ServerScriptService.Server.Data.SessionLockedStore

	Built-in, ProfileService-compatible profile store used when the ProfileService
	package is not installed. It implements the guarantees the game relies on:

	  * Session locking: a profile can be active on only one server. The lock lives in
	    the stored record (MetaData.ActiveSession) and is written atomically with
	    UpdateAsync. A joining server waits for the previous server to release; a lock
	    that has not been refreshed for StaleLockSeconds (crashed server) is taken over.
	  * Lock ownership is re-checked on every save. If another server stole the session,
	    the save is cancelled (never overwriting newer data) and the profile is released
	    with reason "SessionStolen" so the game can kick the player safely.
	  * Saves are serialized per profile: a save requested while one is running is
	    coalesced into a single follow-up save. Released profiles never save again.
	  * Autosave refreshes the lock timestamp of every active profile.

	The backing store only needs UpdateAsync(key, transform), so the in-memory
	MemoryDataStore below can stand in for a DataStore in Studio and in unit tests.

	Dependencies: Shared.Utilities.TableUtil

	API:
		SessionLockedStore.new(options) -> Store
			options = { Name, Template, DataStore (UpdateAsync), SessionId, IsTemporary,
			            StaleLockSeconds, LoadAttempts, LoadRetryDelay, SaveAttempts,
			            Clock?: () -> number, Wait?: (seconds) -> () }
		Store:LoadProfileAsync(key, userId) -> (Profile?, string?)
		Store:SaveAllAsync()                       -- one autosave pass
		Store:ReleaseAllAsync(timeoutSeconds)      -- shutdown
		Store:GetActiveProfiles() -> { Profile }
		SessionLockedStore.MemoryDataStore.new() -> in-memory UpdateAsync backend

	Profile:
		.Data, .Key, .UserId, .IsTemporary
		:IsActive() -> boolean
		:Reconcile()                 -- fill keys missing from the template
		:Save()                      -- asynchronous save request
		:SaveAsync() -> boolean      -- yields until the save attempt finishes
		:Release()                   -- final save + unlock (asynchronous)
		:ReleaseAsync()              -- yields until released
		:ListenToRelease(callback(reason))
		:AddUserId(userId)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TableUtil = require(ReplicatedStorage.Shared.Utilities.TableUtil)

type Record = {
	Data: { [string]: any },
	MetaData: {
		ActiveSession: { SessionId: string, PlaceId: number }?,
		LastUpdate: number,
		SessionLoadCount: number,
		FormatVersion: number,
	},
}

local FORMAT_VERSION = 1

-- In-memory backend ---------------------------------------------------------------

local MemoryDataStore = {}
MemoryDataStore.__index = MemoryDataStore

function MemoryDataStore.new()
	return setmetatable({ _records = {} :: { [string]: any } }, MemoryDataStore)
end

function MemoryDataStore:UpdateAsync(key: string, transform: (any, any) -> any): any
	-- Stored values are deep-copied in and out to mimic DataStore serialization: the
	-- caller must never be able to mutate stored data by reference.
	local current = TableUtil.DeepCopy(self._records[key])
	local result = transform(current, nil)
	if result == nil then
		return nil
	end
	self._records[key] = TableUtil.DeepCopy(result)
	return TableUtil.DeepCopy(result)
end

function MemoryDataStore:GetRaw(key: string): any
	return TableUtil.DeepCopy(self._records[key])
end

-- Profile ------------------------------------------------------------------------

local Profile = {}
Profile.__index = Profile

export type Profile = typeof(setmetatable(
	{} :: {
		Key: string,
		UserId: number,
		Data: { [string]: any },
		IsTemporary: boolean,
		_store: any,
		_active: boolean,
		_releasing: boolean,
		_saving: boolean,
		_saveQueued: boolean,
		_releaseListeners: { (reason: string) -> () },
		_userIds: { number },
		_releasedEvent: BindableEvent?,
	},
	Profile
))

function Profile.IsActive(self: Profile): boolean
	return self._active
end

function Profile.Reconcile(self: Profile)
	TableUtil.Reconcile(self.Data, self._store._template)
end

function Profile.AddUserId(self: Profile, userId: number)
	if not table.find(self._userIds, userId) then
		table.insert(self._userIds, userId)
	end
end

function Profile.ListenToRelease(self: Profile, callback: (reason: string) -> ())
	if not self._active and not self._releasing then
		task.spawn(callback, "AlreadyReleased")
		return
	end
	table.insert(self._releaseListeners, callback)
end

function Profile._markReleased(self: Profile, reason: string)
	if not self._active then
		return
	end
	self._active = false
	self._store:_forget(self)
	for _, listener in self._releaseListeners do
		task.spawn(listener, reason)
	end
	table.clear(self._releaseListeners)
end

-- One UpdateAsync round trip. Returns "Saved", "Stolen" or "Failed".
function Profile._writeOnce(self: Profile, release: boolean): string
	local store = self._store
	local stolen = false
	local snapshot = TableUtil.DeepCopy(self.Data)
	local ok, err = pcall(function()
		store._dataStore:UpdateAsync(self.Key, function(old: Record?)
			local record: Record = old
				or {
					Data = {},
					MetaData = {
						ActiveSession = nil,
						LastUpdate = 0,
						SessionLoadCount = 0,
						FormatVersion = FORMAT_VERSION,
					},
				}
			local session = record.MetaData.ActiveSession
			if session ~= nil and session.SessionId ~= store._sessionId then
				-- Another server owns this profile now. Cancel the write.
				stolen = true
				return nil
			end
			record.Data = snapshot
			record.MetaData.LastUpdate = store._clock()
			record.MetaData.ActiveSession = if release
				then nil
				else { SessionId = store._sessionId, PlaceId = game.PlaceId }
			return record, self._userIds
		end)
	end)
	if not ok then
		warn(`[SessionLockedStore] save of {self.Key} failed: {err}`)
		return "Failed"
	end
	return if stolen then "Stolen" else "Saved"
end

function Profile._runSave(self: Profile, release: boolean): boolean
	local store = self._store
	if self.IsTemporary then
		if release then
			self:_markReleased("Released")
		end
		return true
	end

	local outcome = "Failed"
	for attempt = 1, store._saveAttempts do
		outcome = self:_writeOnce(release)
		if outcome ~= "Failed" then
			break
		end
		if attempt < store._saveAttempts then
			store._wait(2 ^ attempt)
		end
	end

	if outcome == "Stolen" then
		warn(`[SessionLockedStore] session for {self.Key} was taken by another server; releasing locally`)
		self:_markReleased("SessionStolen")
		return false
	end
	if release then
		-- Even if the final write failed the profile must stop being used here; the
		-- stale-lock timeout lets the next server take over safely.
		self:_markReleased(if outcome == "Saved" then "Released" else "ReleasedWithError")
	end
	return outcome == "Saved"
end

function Profile.SaveAsync(self: Profile): boolean
	if not self._active or self._releasing then
		return false
	end
	if self._saving then
		self._saveQueued = true
		return true
	end
	self._saving = true
	local ok = self:_runSave(false)
	-- Coalesce saves requested while this one was in flight into one more write.
	while self._saveQueued and self._active and not self._releasing do
		self._saveQueued = false
		ok = self:_runSave(false)
	end
	self._saving = false
	return ok
end

function Profile.Save(self: Profile)
	task.spawn(function()
		self:SaveAsync()
	end)
end

function Profile.ReleaseAsync(self: Profile)
	if not self._active then
		return
	end
	if self._releasing then
		-- Another thread is already releasing; wait for it.
		local event = self._releasedEvent
		if event then
			event.Event:Wait()
		end
		return
	end
	self._releasing = true
	local event = Instance.new("BindableEvent")
	self._releasedEvent = event
	-- Let an in-flight save finish first so writes stay ordered.
	while self._saving do
		self._store._wait(0.1)
	end
	self:_runSave(true)
	event:Fire()
	event:Destroy()
	self._releasedEvent = nil
end

function Profile.Release(self: Profile)
	task.spawn(function()
		self:ReleaseAsync()
	end)
end

-- Store ----------------------------------------------------------------------------

local SessionLockedStore = {}
SessionLockedStore.__index = SessionLockedStore
SessionLockedStore.MemoryDataStore = MemoryDataStore

export type StoreOptions = {
	Name: string,
	Template: { [string]: any },
	DataStore: any,
	SessionId: string,
	IsTemporary: boolean,
	StaleLockSeconds: number,
	LoadAttempts: number,
	LoadRetryDelay: number,
	SaveAttempts: number,
	Clock: (() -> number)?,
	Wait: ((number) -> ())?,
}

function SessionLockedStore.new(options: StoreOptions)
	return setmetatable({
		Name = options.Name,
		_template = options.Template,
		_dataStore = options.DataStore,
		_sessionId = options.SessionId,
		_isTemporary = options.IsTemporary,
		_staleLock = options.StaleLockSeconds,
		_loadAttempts = options.LoadAttempts,
		_loadRetryDelay = options.LoadRetryDelay,
		_saveAttempts = options.SaveAttempts,
		_clock = options.Clock or os.time,
		_wait = options.Wait or task.wait,
		_profiles = {} :: { [string]: Profile },
		_loading = {} :: { [string]: boolean },
	}, SessionLockedStore)
end

function SessionLockedStore:_forget(profile: Profile)
	if self._profiles[profile.Key] == profile then
		self._profiles[profile.Key] = nil
	end
end

function SessionLockedStore:GetActiveProfiles(): { Profile }
	local list = {}
	for _, profile in self._profiles do
		table.insert(list, profile)
	end
	return list
end

-- Attempts to acquire the session lock once. Returns ("Acquired", record) |
-- ("Locked", nil) | ("Error", message).
function SessionLockedStore:_tryAcquire(key: string, userId: number): (string, any)
	local now = self._clock()
	local sessionId = self._sessionId
	local staleAfter = self._staleLock
	local status = "Error"
	local acquiredRecord: Record? = nil

	local ok, err = pcall(function()
		self._dataStore:UpdateAsync(key, function(old: Record?)
			local record: Record = old
				or {
					Data = TableUtil.DeepCopy(self._template),
					MetaData = {
						ActiveSession = nil,
						LastUpdate = 0,
						SessionLoadCount = 0,
						FormatVersion = FORMAT_VERSION,
					},
				}
			-- Older raw records without MetaData are wrapped instead of discarded.
			if type(record.MetaData) ~= "table" then
				record = {
					Data = record :: any,
					MetaData = { ActiveSession = nil, LastUpdate = 0, SessionLoadCount = 0, FormatVersion = FORMAT_VERSION },
				}
			end
			local session = record.MetaData.ActiveSession
			local lockIsFresh = (now - (record.MetaData.LastUpdate or 0)) < staleAfter
			if session ~= nil and session.SessionId ~= sessionId and lockIsFresh then
				status = "Locked"
				return nil
			end
			record.MetaData.ActiveSession = { SessionId = sessionId, PlaceId = game.PlaceId }
			record.MetaData.LastUpdate = now
			record.MetaData.SessionLoadCount = (record.MetaData.SessionLoadCount or 0) + 1
			status = "Acquired"
			acquiredRecord = record
			return record, { userId }
		end)
	end)

	if not ok then
		return "Error", tostring(err)
	end
	return status, acquiredRecord
end

function SessionLockedStore:LoadProfileAsync(key: string, userId: number): (Profile?, string?)
	if self._profiles[key] or self._loading[key] then
		return nil, "profile already loaded or loading on this server"
	end
	self._loading[key] = true

	local record: Record? = nil
	local lastProblem = "unknown"

	if self._isTemporary then
		record = {
			Data = TableUtil.DeepCopy(self._template),
			MetaData = { ActiveSession = nil, LastUpdate = 0, SessionLoadCount = 1, FormatVersion = FORMAT_VERSION },
		}
	else
		for attempt = 1, self._loadAttempts do
			local status, result = self:_tryAcquire(key, userId)
			if status == "Acquired" then
				record = result
				break
			elseif status == "Locked" then
				lastProblem = "profile is active on another server"
			else
				lastProblem = result
				warn(`[SessionLockedStore] load of {key} attempt {attempt} failed: {result}`)
			end
			if attempt < self._loadAttempts then
				self._wait(self._loadRetryDelay)
			end
		end
	end

	self._loading[key] = nil
	if record == nil then
		return nil, lastProblem
	end

	local profile = setmetatable({
		Key = key,
		UserId = userId,
		Data = record.Data,
		IsTemporary = self._isTemporary,
		_store = self,
		_active = true,
		_releasing = false,
		_saving = false,
		_saveQueued = false,
		_releaseListeners = {},
		_userIds = { userId },
		_releasedEvent = nil,
	}, Profile) :: Profile
	self._profiles[key] = profile
	return profile, nil
end

function SessionLockedStore:SaveAllAsync()
	for _, profile in self:GetActiveProfiles() do
		task.spawn(function()
			profile:SaveAsync()
		end)
	end
end

function SessionLockedStore:ReleaseAllAsync(timeoutSeconds: number)
	local profiles = self:GetActiveProfiles()
	local remaining = #profiles
	if remaining == 0 then
		return
	end
	local done = Instance.new("BindableEvent")
	for _, profile in profiles do
		task.spawn(function()
			profile:ReleaseAsync()
			remaining -= 1
			if remaining == 0 then
				done:Fire()
			end
		end)
	end
	local timeoutThread = task.delay(timeoutSeconds, function()
		done:Fire()
	end)
	if remaining > 0 then
		done.Event:Wait()
	end
	pcall(task.cancel, timeoutThread)
	done:Destroy()
end

return SessionLockedStore
