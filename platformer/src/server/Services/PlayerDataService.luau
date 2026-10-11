--!strict
-- Authoritative, persisted player progression.
--
-- Lifecycle per player:
--   Loading   -> session lock acquired with UpdateAsync, data normalised/migrated
--   Ready     -> mutations allowed; leaderstats mirror the data
--   Releasing -> final save that also clears the lock
--   Released  -> profile discarded
--
-- Safety policy:
--   * If data cannot be loaded (DataStore errors after bounded retries, lock
--     held by another live server, or data from a newer schema), the player
--     is kicked with an explanation. Defaults are never substituted and
--     never written over existing data.
--   * Every write checks, inside UpdateAsync, that this server still owns
--     the lock. A server that lost its lock stops saving and kicks the player.
--   * Saves for one player never overlap: a save requested while one is
--     running is queued and runs once the first finishes.
--
-- Only this module mutates PlayerData. Currency changes go through
-- AddCurrency, which is the single authoritative grant path.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local DataConfig = require(Shared.Config.DataConfig)
local Logger = require(Shared.Utilities.Logger)
local Types = require(Shared.Types)

local Utilities = script.Parent.Parent.Utilities
local DataSchema = require(Utilities.DataSchema)
local DataStoreRetry = require(Utilities.DataStoreRetry)
local MemoryDataStore = require(Utilities.MemoryDataStore)
local ProfileStore = require(Utilities.ProfileStore)

type PlayerData = Types.PlayerData
type CurrencyType = Types.CurrencyType

type ProfileState = "Loading" | "Ready" | "Releasing" | "Released"

type Profile = {
	Player: Player,
	UserId: number,
	Key: string,
	State: ProfileState,
	Data: PlayerData?,
	CollectedCount: number,
	Dirty: boolean,
	LockRefreshedAt: number,
	Abandoned: boolean,
	SessionLost: boolean,
	Saving: boolean,
	ResaveRequested: boolean,
	ReleaseRequested: boolean,
	SaveWaiters: { thread },
	ReleaseWaiters: { thread },
	ReleaseResult: boolean?,
	Leaderstats: { [string]: IntValue },
}

local CURRENCIES: { CurrencyType } = { "Shards", "PowerOrbs" }
local PREVIOUS_SESSION_POLL = 0.25

local logger = Logger.new("PlayerDataService")

local PlayerDataService = {}

local profiles: { [Player]: Profile } = {}
local profilesByUserId: { [number]: Profile } = {}
local readyCallbacks: { (player: Player) -> () } = {}
local store: ProfileStore.Store? = nil
local usingMemoryStore = false
local jobId = ""
local started = false
local shuttingDown = false
local activeOperations = 0

local function kick(player: Player, message: string)
	if player.Parent == Players then
		player:Kick(message)
	end
end

local function waitForBudget()
	if usingMemoryStore then
		return
	end
	local deadline = os.clock() + DataConfig.Retry.BudgetWaitTimeout
	while os.clock() < deadline do
		local ok, budget = pcall(
			DataStoreService.GetRequestBudgetForRequestType,
			DataStoreService,
			Enum.DataStoreRequestType.UpdateAsync
		)
		if not ok or budget >= 1 then
			return
		end
		task.wait(0.25)
	end
end

local retryOptions: DataStoreRetry.Options = {
	MaxAttempts = DataConfig.Retry.MaxAttempts,
	BaseDelay = DataConfig.Retry.BaseDelay,
	MaxDelay = DataConfig.Retry.MaxDelay,
	JitterFraction = DataConfig.Retry.JitterFraction,
	BeforeAttempt = waitForBudget,
	OnRetry = function(attempt: number, message: string, delay: number)
		logger:Warn("DataStoreRetry", { Attempt = attempt, Error = message, Delay = string.format("%.2f", delay) })
	end,
}

local function storeOptions(): ProfileStore.Options
	return {
		JobId = jobId,
		PlaceId = game.PlaceId,
		LockTimeout = DataConfig.Session.LockTimeout,
		Now = os.time,
		Retry = retryOptions,
	}
end

local function getStore(): ProfileStore.Store
	return assert(store, "PlayerDataService used before Start")
end

local function readyProfile(player: Player): Profile?
	local profile = profiles[player]
	if profile and profile.State == "Ready" and not profile.SessionLost and profile.Data then
		return profile
	end
	return nil
end

local function countCollected(data: PlayerData): number
	local count = 0
	for _ in data.CollectedCollectibles do
		count += 1
	end
	return count
end

local function resumeAll(threads: { thread }, ...: any)
	for _, thread in threads do
		task.spawn(thread, ...)
	end
end

-- One UpdateAsync write of the current data.
local function writeOnce(profile: Profile, release: boolean): (boolean, string?)
	local data = profile.Data
	if not data then
		return false, "NoData"
	end
	if profile.SessionLost then
		return false, "SessionLost"
	end
	local snapshot = DataSchema.Copy(data)
	local wasDirty = profile.Dirty
	profile.Dirty = false

	local result = ProfileStore.Write(getStore(), profile.Key, profile.UserId, snapshot, release, storeOptions())
	if result.Status == "Saved" then
		profile.LockRefreshedAt = os.time()
		return true, nil
	end

	profile.Dirty = profile.Dirty or wasDirty
	if result.Status == "LostLock" then
		profile.SessionLost = true
		logger:Error("SessionLost", { UserId = profile.UserId, Detail = result.Error })
		kick(profile.Player, DataConfig.KickMessages.SessionLost)
		return false, "SessionLost"
	end
	logger:Error("SaveFailed", { UserId = profile.UserId, Release = release, Error = result.Error })
	return false, "SaveFailed"
end

-- Serialised save: concurrent callers wait for (and share) the running save,
-- and a request made during a save causes one more write afterwards so the
-- newest data is always the last thing written.
local function saveProfile(profile: Profile, release: boolean): (boolean, string?)
	if release then
		profile.ReleaseRequested = true
	end
	if profile.Saving then
		profile.ResaveRequested = true
		table.insert(profile.SaveWaiters, coroutine.running())
		return coroutine.yield()
	end

	profile.Saving = true
	local ok: boolean, reason: string? = false, nil
	repeat
		profile.ResaveRequested = false
		ok, reason = writeOnce(profile, profile.ReleaseRequested)
	until not profile.ResaveRequested or profile.SessionLost
	profile.Saving = false

	local waiters = profile.SaveWaiters
	profile.SaveWaiters = {}
	resumeAll(waiters, ok, reason)
	return ok, reason
end

local function createLeaderstats(profile: Profile)
	local data = profile.Data :: PlayerData
	local player = profile.Player
	local old = player:FindFirstChild("leaderstats")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	for _, currency in CURRENCIES do
		local value = Instance.new("IntValue")
		value.Name = currency
		value.Value = data[currency]
		value.Parent = folder
		profile.Leaderstats[currency] = value
	end
	folder.Parent = player
end

local function forgetProfile(profile: Profile)
	if profiles[profile.Player] == profile then
		profiles[profile.Player] = nil
	end
	if profilesByUserId[profile.UserId] == profile then
		profilesByUserId[profile.UserId] = nil
	end
end

local function logLoadReport(profile: Profile, result: ProfileStore.AcquireResult)
	local report = result.Report
	if result.TookExpiredLock then
		logger:Warn("TookExpiredSessionLock", { UserId = profile.UserId })
	end
	if not report then
		return
	end
	if report.Status == "Corrupt" then
		logger:Error("CorruptDataReset", { UserId = profile.UserId, Issues = table.concat(report.Issues, "; ") })
	elseif report.Status == "Repaired" then
		logger:Warn("DataRepaired", { UserId = profile.UserId, Issues = table.concat(report.Issues, "; ") })
	end
end

-- Waits (bounded) for a previous profile of the same user on this server,
-- e.g. a fast leave-and-rejoin, to finish releasing. Our own JobId counts as
-- "Owned" in the lock, so without this the two profiles could overlap.
local function waitForPreviousSession(profile: Profile): boolean
	local deadline = os.clock() + DataConfig.ShutdownTimeout
	while true do
		local previous = profilesByUserId[profile.UserId]
		if previous == nil or previous == profile then
			profilesByUserId[profile.UserId] = profile
			return true
		end
		if os.clock() > deadline or profile.Abandoned then
			return false
		end
		task.wait(PREVIOUS_SESSION_POLL)
	end
end

local function loadProfile(player: Player)
	local profile: Profile = {
		Player = player,
		UserId = player.UserId,
		Key = DataConfig.KeyPrefix .. tostring(player.UserId),
		State = "Loading",
		Data = nil,
		CollectedCount = 0,
		Dirty = false,
		LockRefreshedAt = 0,
		Abandoned = false,
		SessionLost = false,
		Saving = false,
		ResaveRequested = false,
		ReleaseRequested = false,
		SaveWaiters = {},
		ReleaseWaiters = {},
		ReleaseResult = nil,
		Leaderstats = {},
	}
	profiles[player] = profile
	activeOperations += 1

	if not waitForPreviousSession(profile) then
		forgetProfile(profile)
		activeOperations -= 1
		if not profile.Abandoned then
			logger:Error("PreviousSessionStuck", { UserId = profile.UserId })
			kick(player, DataConfig.KickMessages.SessionLocked)
		end
		return
	end

	local result: ProfileStore.AcquireResult = { Status = "Failed", TookExpiredLock = false, Error = "not attempted" }
	for attempt = 1, DataConfig.Session.AcquireAttempts do
		result = ProfileStore.Acquire(getStore(), profile.Key, profile.UserId, storeOptions())
		if result.Status ~= "Locked" or attempt == DataConfig.Session.AcquireAttempts or profile.Abandoned then
			break
		end
		logger:Info("SessionLockedRetrying", { UserId = profile.UserId, Holder = result.LockHolder, Attempt = attempt })
		task.wait(DataConfig.Session.AcquireRetryDelay)
		if profile.Abandoned then
			break
		end
	end

	if result.Status == "Acquired" and result.Data then
		profile.Data = result.Data
		profile.CollectedCount = countCollected(result.Data)
		profile.LockRefreshedAt = os.time()
		logLoadReport(profile, result)

		if profile.Abandoned or player.Parent ~= Players then
			-- Left during the load: hand the lock straight back.
			profile.State = "Releasing"
			local released = saveProfile(profile, true)
			profile.State = "Released"
			profile.ReleaseResult = released
			forgetProfile(profile)
			activeOperations -= 1
			return
		end

		profile.State = "Ready"
		createLeaderstats(profile)
		activeOperations -= 1
		logger:Debug("ProfileReady", { UserId = profile.UserId, Status = result.Report and result.Report.Status })
		for _, callback in readyCallbacks do
			task.spawn(callback, player)
		end
		return
	end

	forgetProfile(profile)
	activeOperations -= 1
	if result.Status == "Locked" then
		if not profile.Abandoned then
			logger:Warn("SessionLocked", { UserId = profile.UserId, Holder = result.LockHolder })
			kick(player, DataConfig.KickMessages.SessionLocked)
		end
	elseif result.Status == "FutureSchema" then
		logger:Error("FutureSchema", { UserId = profile.UserId })
		kick(player, DataConfig.KickMessages.FutureSchema)
	else
		logger:Error("LoadFailed", { UserId = profile.UserId, Error = result.Error })
		kick(player, DataConfig.KickMessages.Unavailable)
	end
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

-- Registers a callback fired (in its own thread) once a player's data is Ready.
function PlayerDataService.OnPlayerDataReady(callback: (player: Player) -> ())
	table.insert(readyCallbacks, callback)
end

-- True once data loaded and the session lock is held.
function PlayerDataService.IsPlayerDataReady(player: Player): boolean
	return readyProfile(player) ~= nil
end

-- Deep-copied snapshot, or nil if not ready. Mutating it has no effect.
function PlayerDataService.GetPlayerData(player: Player): PlayerData?
	local profile = readyProfile(player)
	return if profile then DataSchema.Copy(profile.Data :: PlayerData) else nil
end

function PlayerDataService.GetCurrency(player: Player, currencyType: CurrencyType): number?
	local profile = readyProfile(player)
	if not profile or not DataSchema.IsCurrencyType(currencyType) then
		return nil
	end
	return (profile.Data :: PlayerData)[currencyType]
end

-- Validates a grant without applying it. Amounts must be positive integers
-- no larger than DataConfig.MaxSingleGrant.
function PlayerDataService.ValidateCurrencyGrant(currencyType: any, amount: any): (boolean, string?)
	if not DataSchema.IsCurrencyType(currencyType) then
		return false, "InvalidCurrencyType"
	end
	if type(amount) ~= "number" or amount ~= amount or amount == math.huge then
		return false, "InvalidAmount"
	end
	if math.floor(amount) ~= amount then
		return false, "NonIntegerAmount"
	end
	if amount <= 0 then
		return false, "NonPositiveAmount"
	end
	if amount > DataConfig.MaxSingleGrant then
		return false, "AmountTooLarge"
	end
	return true, nil
end

-- The single authoritative currency path. Returns (true, newTotal) or
-- (false, reason). Totals are clamped at DataConfig.MaxCurrency.
function PlayerDataService.AddCurrency(
	player: Player,
	currencyType: CurrencyType,
	amount: number,
	source: string
): (boolean, number | string)
	local valid, reason = PlayerDataService.ValidateCurrencyGrant(currencyType, amount)
	if not valid then
		logger:Warn("CurrencyRejected", { UserId = player.UserId, Type = currencyType, Amount = amount, Reason = reason, Source = source })
		return false, reason :: string
	end
	local profile = readyProfile(player)
	if not profile then
		return false, "DataNotReady"
	end
	local data = profile.Data :: PlayerData
	local total = math.min(data[currencyType] + amount, DataConfig.MaxCurrency)
	if total < data[currencyType] + amount then
		logger:Warn("CurrencyCapped", { UserId = player.UserId, Type = currencyType })
	end
	data[currencyType] = total
	profile.Dirty = true
	local stat = profile.Leaderstats[currencyType]
	if stat then
		stat.Value = total
	end
	return true, total
end

-- nil when data is not ready; otherwise whether the id is stored.
function PlayerDataService.HasCollected(player: Player, collectibleId: string): boolean?
	local profile = readyProfile(player)
	if not profile then
		return nil
	end
	return (profile.Data :: PlayerData).CollectedCollectibles[collectibleId] == true
end

-- Idempotent claim of a persistent collectible id. Returns (true) when newly
-- marked, (false, reason) otherwise: InvalidId, DataNotReady,
-- AlreadyCollected, CollectionLimitReached.
function PlayerDataService.MarkCollected(player: Player, collectibleId: string): (boolean, string?)
	if not DataSchema.IsValidCollectibleId(collectibleId) then
		return false, "InvalidId"
	end
	local profile = readyProfile(player)
	if not profile then
		return false, "DataNotReady"
	end
	local collected = (profile.Data :: PlayerData).CollectedCollectibles
	if collected[collectibleId] then
		return false, "AlreadyCollected"
	end
	if profile.CollectedCount >= DataConfig.MaxCollectedIds then
		logger:Error("CollectionLimitReached", { UserId = player.UserId })
		return false, "CollectionLimitReached"
	end
	collected[collectibleId] = true
	profile.CollectedCount += 1
	profile.Dirty = true
	return true, nil
end

-- Rolls back a MarkCollected whose reward could not be granted.
function PlayerDataService.UnmarkCollected(player: Player, collectibleId: string): boolean
	local profile = readyProfile(player)
	if not profile then
		return false
	end
	local collected = (profile.Data :: PlayerData).CollectedCollectibles
	if not collected[collectibleId] then
		return false
	end
	collected[collectibleId] = nil
	profile.CollectedCount -= 1
	profile.Dirty = true
	return true
end

function PlayerDataService.GetCollectedIds(player: Player): { string }?
	local profile = readyProfile(player)
	if not profile then
		return nil
	end
	local ids = {}
	for id in (profile.Data :: PlayerData).CollectedCollectibles do
		table.insert(ids, id)
	end
	return ids
end

-- Saves now (yields). Returns (true) or (false, reason).
function PlayerDataService.SavePlayerData(player: Player): (boolean, string?)
	local profile = readyProfile(player)
	if not profile then
		return false, "DataNotReady"
	end
	return saveProfile(profile, false)
end

-- Final save + lock release (yields). Idempotent; concurrent callers wait for
-- the same result. A player still loading is marked abandoned and the loader
-- releases the lock once the load completes.
function PlayerDataService.ReleasePlayerSession(player: Player): boolean
	local profile = profiles[player]
	if not profile then
		return true
	end
	if profile.State == "Loading" then
		profile.Abandoned = true
		return true
	end
	if profile.State == "Released" then
		return profile.ReleaseResult == true
	end
	if profile.State == "Releasing" then
		table.insert(profile.ReleaseWaiters, coroutine.running())
		return coroutine.yield()
	end

	profile.State = "Releasing"
	activeOperations += 1
	local ok = if profile.SessionLost then false else (saveProfile(profile, true))
	profile.State = "Released"
	profile.ReleaseResult = ok
	forgetProfile(profile)
	activeOperations -= 1

	local waiters = profile.ReleaseWaiters
	profile.ReleaseWaiters = {}
	resumeAll(waiters, ok)
	return ok
end

function PlayerDataService.IsUsingMemoryStore(): boolean
	return usingMemoryStore
end

------------------------------------------------------------------------------
-- Startup
------------------------------------------------------------------------------

local function createStore(): ProfileStore.Store
	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, DataConfig.DataStoreName)
	local dataStore: DataStore? = if ok then result :: DataStore else nil
	local problem: string? = if ok then nil else tostring(result)

	if RunService:IsStudio() and DataConfig.UseMemoryStoreInStudio then
		if dataStore then
			local probeOk, probeError = pcall(function()
				return (dataStore :: DataStore):GetAsync("__studio_probe")
			end)
			if not probeOk then
				problem = tostring(probeError)
			end
		end
		if problem then
			usingMemoryStore = true
			logger:Warn("UsingMemoryStore", {
				Reason = problem,
				Note = "Studio only; progress is discarded when the session stops. Enable Studio API access to test real saves.",
			})
			local memory = MemoryDataStore.new()
			return {
				UpdateAsync = function(_, key, transform)
					return memory:UpdateAsync(key, transform)
				end,
			}
		end
	end

	if not dataStore then
		error(`DataStore "{DataConfig.DataStoreName}" unavailable: {problem}`)
	end
	local liveStore = dataStore :: DataStore
	return {
		UpdateAsync = function(_, key, transform)
			return liveStore:UpdateAsync(key, transform)
		end,
	}
end

local function autosaveLoop()
	while not shuttingDown do
		task.wait(DataConfig.AutosaveInterval)
		if shuttingDown then
			break
		end
		local now = os.time()
		local due: { Profile } = {}
		for _, profile in profiles do
			if
				profile.State == "Ready"
				and not profile.SessionLost
				and (profile.Dirty or now - profile.LockRefreshedAt >= DataConfig.LockRefreshAge)
			then
				table.insert(due, profile)
			end
		end
		-- Spread writes over at most a quarter of the interval.
		local stagger = if #due > 0 then math.min(0.5, DataConfig.AutosaveInterval * 0.25 / #due) else 0
		for _, profile in due do
			if profile.State == "Ready" then
				task.spawn(saveProfile, profile, false)
				task.wait(stagger)
			end
		end
	end
end

local function onShutdown()
	shuttingDown = true
	local list: { Player } = {}
	for player in profiles do
		table.insert(list, player)
	end
	for _, player in list do
		task.spawn(PlayerDataService.ReleasePlayerSession, player)
	end
	local deadline = os.clock() + DataConfig.ShutdownTimeout
	while activeOperations > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
	if activeOperations > 0 then
		logger:Error("ShutdownSaveTimeout", { Pending = activeOperations })
	end
end

function PlayerDataService.Start()
	assert(not started, "PlayerDataService already started")
	started = true
	assert(
		DataConfig.Session.LockTimeout > DataConfig.LockRefreshAge + DataConfig.AutosaveInterval,
		"DataConfig: LockTimeout must exceed LockRefreshAge + AutosaveInterval"
	)

	jobId = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)
	store = createStore()

	Players.PlayerAdded:Connect(function(player)
		if not shuttingDown then
			loadProfile(player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		PlayerDataService.ReleasePlayerSession(player)
	end)
	for _, player in Players:GetPlayers() do
		if not profiles[player] then
			task.spawn(loadProfile, player)
		end
	end

	game:BindToClose(onShutdown)
	task.spawn(autosaveLoop)
end

return PlayerDataService
