--!strict
--[[
	DataConfig
	Path: ServerScriptService.Server.Data.DataConfig

	Persistence settings. Server-only: clients never need DataStore names or timings.

	StoreName        DataStore name; bump the suffix only for a deliberate full wipe
	KeyPrefix        profile key = KeyPrefix .. UserId
	AutoSaveInterval every active profile is saved (and its session lock refreshed) this often
	StaleLockSeconds a session lock older than this is considered abandoned (crashed server)
	                 and may be taken over; must be far larger than AutoSaveInterval
	LoadAttempts / LoadRetryDelay  how long a joining player waits for another server to
	                 release their profile (server hopping)
	SaveAttempts     retries per save with exponential backoff
	UseMockInStudio  in Studio, use an in-memory store (no writes to real data)
	ForceMock        always use the in-memory store (automated tests / offline places)
]]

return table.freeze({
	StoreName = "PumpkinFarm_Profiles_v1",
	KeyPrefix = "Player_",
	AutoSaveInterval = 60,
	StaleLockSeconds = 600,
	LoadAttempts = 8,
	LoadRetryDelay = 5,
	SaveAttempts = 3,
	UseMockInStudio = true,
	ForceMock = false,
	-- How long BindToClose waits for final saves before letting the server close.
	ShutdownTimeout = 25,
})
