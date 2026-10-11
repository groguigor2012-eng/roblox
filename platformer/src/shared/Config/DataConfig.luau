--!strict
-- Persistence settings. Shared so the client can read the schema version for
-- debugging; it contains no credentials and grants nothing.
--
-- Stored record (one DataStore key per player, "<KeyPrefix><UserId>"):
--   {
--     FormatVersion = 1,
--     Data = { SchemaVersion, Shards, PowerOrbs, CollectedCollectibles },
--     Session = { JobId, PlaceId, LockedAt } | nil,   -- nil = not locked
--     LastSaved = <os.time()>,
--   }

local DataConfig = {}

DataConfig.DataStoreName = "PlatformerPlayerData"
DataConfig.KeyPrefix = "Player_"

-- Current PlayerData schema. Bump it and add a migration in DataSchema when
-- the layout changes.
DataConfig.SchemaVersion = 1

-- Hard ceiling for each currency (also keeps IntValue leaderstats sane).
DataConfig.MaxCurrency = 1_000_000_000
-- Largest single AddCurrency grant accepted.
DataConfig.MaxSingleGrant = 10_000
-- Upper bound on stored collectible ids per player (keeps the record well
-- under the 4 MB DataStore value limit: 20k ids * ~70 bytes ≈ 1.4 MB).
DataConfig.MaxCollectedIds = 20_000

DataConfig.Retry = table.freeze({
	MaxAttempts = 5,
	-- delay(attempt) = min(MaxDelay, BaseDelay * 2^(attempt-1)) * (1 + JitterFraction * random[0,1))
	BaseDelay = 0.5,
	MaxDelay = 8,
	JitterFraction = 0.3,
	-- Max seconds to wait for DataStore request budget before trying anyway.
	BudgetWaitTimeout = 5,
})

DataConfig.Session = table.freeze({
	-- A lock not refreshed for this long belongs to a dead server and may be taken.
	LockTimeout = 300,
	-- Attempts to take a lock held by another live server (e.g. fast server hop).
	AcquireAttempts = 5,
	AcquireRetryDelay = 3,
})

-- Autosave runs this often. Clean profiles are only written when their lock
-- is older than LockRefreshAge, so idle players cost one write per refresh.
DataConfig.AutosaveInterval = 60
DataConfig.LockRefreshAge = 120

-- Total time BindToClose spends releasing sessions (Roblox allows 30 s).
DataConfig.ShutdownTimeout = 25

-- In Studio only: if DataStores are unreachable (API access off or place
-- unpublished), fall back to an in-memory store that is discarded on stop.
-- Live servers never fall back; they refuse to load data instead.
DataConfig.UseMemoryStoreInStudio = true

DataConfig.KickMessages = table.freeze({
	Unavailable = "Your saved progress could not be loaded right now, so you have been disconnected to keep it safe. Please rejoin in a minute.",
	SessionLocked = "Your progress is still open on another server. Please wait a moment and rejoin.",
	SessionLost = "Your progress was opened on another server. Rejoin to keep playing there.",
	FutureSchema = "This server is out of date for your saved progress. Please rejoin to get a newer server.",
	ServerUnavailable = "This server could not start its save system. Please rejoin.",
})

return table.freeze(DataConfig)
