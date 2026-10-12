-- Thin adapter over ProfileStore (MadStudioRoblox/ProfileStore, vendored in
-- ServerScriptService.Packages.ProfileStore, Apache-2.0). ProfileStore provides session
-- locking (a profile can only be active on one server at a time), periodic autosave,
-- release on leave and BindToClose flushing. This adapter only:
--   * picks the live or mock store (mock by default in Studio),
--   * cancels a load if the player leaves while it is in progress,
--   * degrades to a clearly-labelled NON-PERSISTENT session in Studio when the package is
--     missing, and refuses to create sessions in live servers in that case.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Signal = require(game:GetService("ReplicatedStorage").Shared.Signal)

export type Session = {
	Data: any,
	IsMock: boolean,
	OnSessionEnd: any, -- signal-like with :Connect
	IsActive: (self: Session) -> boolean,
	Reconcile: (self: Session) -> (),
	EndSession: (self: Session) -> (),
	AddUserId: (self: Session, userId: number) -> (),
	Save: (self: Session) -> (),
}

local ProfileStoreAdapter = {}
ProfileStoreAdapter.__index = ProfileStoreAdapter

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, inner in value :: any do
		copy[key] = deepCopy(inner)
	end
	return copy :: any
end

local function loadProfileStore(): any?
	local packages = ServerScriptService:FindFirstChild("Packages")
	local module = packages and packages:FindFirstChild("ProfileStore")
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	if not ok then
		warn(`[Data] ProfileStore failed to load: {result}`)
		return nil
	end
	return result
end

-- In-memory session used ONLY in Studio when ProfileStore is unavailable. Nothing is saved.
local function newTransientSession(template: any): Session
	local session = {
		Data = deepCopy(template),
		IsMock = true,
		OnSessionEnd = Signal.new(),
		_active = true,
	}
	function session.IsActive(self)
		return self._active
	end
	function session.Reconcile(_self) end
	function session.EndSession(self)
		if self._active then
			self._active = false
			self.OnSessionEnd:Fire()
		end
	end
	function session.AddUserId(_self, _userId) end
	function session.Save(_self) end
	return session :: any
end

function ProfileStoreAdapter.new(storeName: string, template: any, useLiveInStudio: boolean)
	local self = setmetatable({}, ProfileStoreAdapter)
	self._template = template
	self._profileStoreModule = loadProfileStore()
	self.Persistent = self._profileStoreModule ~= nil
	self.UsingMock = false

	if self._profileStoreModule then
		local ProfileStore = self._profileStoreModule
		self._store = ProfileStore.New(storeName, template)
		if RunService:IsStudio() and not useLiveInStudio then
			self.UsingMock = true
		end
		ProfileStore.OnError:Connect(function(message, store, key)
			warn(`[Data] ProfileStore error ({store}/{key}): {message}`)
		end)
		ProfileStore.OnCriticalToggle:Connect(function(isCritical)
			if isCritical then
				warn("[Data] ProfileStore entered critical state: DataStore requests are failing repeatedly.")
			end
		end)
	elseif RunService:IsStudio() then
		warn(
			"[Data] ServerScriptService.Packages.ProfileStore is missing. Running with NON-PERSISTENT "
				.. "profiles (Studio only). Install ProfileStore to enable saving; see TameAPet/README.md."
		)
	else
		warn("[Data] ProfileStore is missing in a live server. Players cannot be given a profile.")
	end
	return self
end

-- Yields. Returns nil if the profile could not be loaded (caller must kick the player and
-- never fall back to a blank profile, which could overwrite their real data).
function ProfileStoreAdapter:startSession(player: Player, key: string): Session?
	if not self._profileStoreModule then
		if RunService:IsStudio() then
			return newTransientSession(self._template)
		end
		return nil
	end

	local store = if self.UsingMock then self._store.Mock else self._store
	local ok, profile = pcall(function()
		return store:StartSessionAsync(key, {
			Cancel = function()
				return player.Parent ~= Players
			end,
		})
	end)
	if not ok then
		warn(`[Data] StartSessionAsync errored for {player.UserId}: {profile}`)
		return nil
	end
	if profile == nil then
		return nil
	end
	profile.IsMock = self.UsingMock
	return profile
end

return ProfileStoreAdapter
