--!strict
--[[
	ProfileServiceWrapper
	Path: ServerScriptService.Server.Data.ProfileServiceWrapper

	Chooses the persistence backend and exposes it through one small interface, so
	DataService never touches DataStore APIs or a specific library directly.

	Backend selection (first match wins):
	  1. ProfileService by loleris - put the ModuleScript at
	     ServerStorage.Packages.ProfileService. Session locking, autosave and release
	     are then handled by ProfileService itself.
	  2. Built-in SessionLockedStore backed by DataStoreService.
	  3. Built-in SessionLockedStore backed by memory ("temporary" profiles, nothing is
	     written) when DataConfig.ForceMock is set, when running in Studio with
	     DataConfig.UseMockInStudio, or when DataStores are unavailable (Studio without
	     API access, or a local file). Temporary profiles are flagged so the UI can warn.

	Dependencies: DataConfig, SessionLockedStore

	API:
		ProfileServiceWrapper.GetStore(template) -> Store
		Store.BackendName : "ProfileService" | "DataStore" | "Memory"
		Store:LoadProfileAsync(userId) -> (Profile?, string?)
		Store:SaveAllAsync()                   -- no-op for ProfileService (it autosaves)
		Store:ReleaseAllAsync(timeoutSeconds)

	Profile (common surface): .Data, .IsTemporary, :IsActive(), :Reconcile(), :Save(),
	:Release(), :ListenToRelease(callback(reason)), :AddUserId(userId)
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local DataConfig = require(script.Parent.DataConfig)
local SessionLockedStore = require(script.Parent.SessionLockedStore)

local ProfileServiceWrapper = {}

-- Adapts a ProfileService profile to the common surface.
local function adaptProfileServiceProfile(profile: any)
	local adapter = {
		Data = profile.Data,
		IsTemporary = false,
		_profile = profile,
	}
	function adapter:IsActive(): boolean
		return profile:IsActive()
	end
	function adapter:Reconcile()
		profile:Reconcile()
		adapter.Data = profile.Data
	end
	function adapter:Save()
		-- ProfileService autosaves; nothing to do.
	end
	function adapter:Release()
		profile:Release()
	end
	function adapter:ListenToRelease(callback: (string) -> ())
		profile:ListenToRelease(function()
			callback("Released")
		end)
	end
	function adapter:AddUserId(userId: number)
		profile:AddUserId(userId)
	end
	return adapter
end

local function createProfileServiceStore(module: ModuleScript, template: { [string]: any })
	local ProfileService = (require :: any)(module)
	local profileStore = ProfileService.GetProfileStore(DataConfig.StoreName, template)
	local activeAdapters: { [any]: any } = {}

	local store = { BackendName = "ProfileService" }

	function store:LoadProfileAsync(userId: number)
		-- "Repeat" until ProfileService decides the remote session is dead, then
		-- "ForceLoad": the documented safe way to wait for another server to release.
		local profile = profileStore:LoadProfileAsync(DataConfig.KeyPrefix .. userId, "ForceLoad")
		if profile == nil then
			return nil, "ProfileService could not load the profile"
		end
		local adapter = adaptProfileServiceProfile(profile)
		activeAdapters[adapter] = true
		profile:ListenToRelease(function()
			activeAdapters[adapter] = nil
		end)
		return adapter, nil
	end

	function store:SaveAllAsync() end

	function store:ReleaseAllAsync(_timeout: number)
		for adapter in activeAdapters do
			adapter:Release()
		end
	end

	return store
end

local function shouldUseMemory(): (boolean, string)
	if DataConfig.ForceMock then
		return true, "DataConfig.ForceMock"
	end
	if RunService:IsStudio() and DataConfig.UseMockInStudio then
		return true, "Studio mock mode (DataConfig.UseMockInStudio)"
	end
	if game.PlaceId == 0 then
		return true, "unpublished place (PlaceId 0)"
	end
	return false, ""
end

local function createBuiltInStore(template: { [string]: any })
	local useMemory, reason = shouldUseMemory()
	local backend: any = nil
	local backendName = "DataStore"

	if not useMemory then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(DataConfig.StoreName)
		end)
		if ok then
			backend = result
		else
			useMemory = true
			reason = `DataStoreService unavailable: {result}`
		end
	end

	if useMemory then
		warn(`[ProfileServiceWrapper] using in-memory profiles, progress will NOT be saved ({reason})`)
		backend = SessionLockedStore.MemoryDataStore.new()
		backendName = "Memory"
	end

	local sessionId = if game.JobId ~= "" then game.JobId else HttpService:GenerateGUID(false)

	local inner = SessionLockedStore.new({
		Name = DataConfig.StoreName,
		Template = template,
		DataStore = backend,
		SessionId = sessionId,
		IsTemporary = useMemory,
		StaleLockSeconds = DataConfig.StaleLockSeconds,
		LoadAttempts = DataConfig.LoadAttempts,
		LoadRetryDelay = DataConfig.LoadRetryDelay,
		SaveAttempts = DataConfig.SaveAttempts,
	})

	local store = { BackendName = backendName }

	function store:LoadProfileAsync(userId: number)
		return inner:LoadProfileAsync(DataConfig.KeyPrefix .. userId, userId)
	end

	function store:SaveAllAsync()
		-- Respect the request budget: if it is nearly exhausted, skip this pass; the
		-- next autosave catches up and locks stay far from StaleLockSeconds.
		if backendName == "DataStore" then
			local okBudget, budget = pcall(function()
				return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
			end)
			if okBudget and budget < #inner:GetActiveProfiles() then
				warn("[ProfileServiceWrapper] DataStore budget low, skipping autosave pass")
				return
			end
		end
		inner:SaveAllAsync()
	end

	function store:ReleaseAllAsync(timeoutSeconds: number)
		inner:ReleaseAllAsync(timeoutSeconds)
	end

	return store
end

function ProfileServiceWrapper.GetStore(template: { [string]: any })
	local packages = ServerStorage:FindFirstChild("Packages")
	local module = packages and packages:FindFirstChild("ProfileService")
	if module and module:IsA("ModuleScript") then
		local ok, storeOrError = pcall(createProfileServiceStore, module, template)
		if ok then
			return storeOrError
		end
		warn(`[ProfileServiceWrapper] ProfileService failed to initialise, using built-in store: {storeOrError}`)
	end
	return createBuiltInStore(template)
end

return ProfileServiceWrapper
