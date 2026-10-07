return function(H)
	local Migrations = H.Module("Server.Data.Migrations")
	local ProfileTemplate = H.Module("Server.Data.ProfileTemplate")
	local SessionLockedStore = H.Module("Server.Data.SessionLockedStore")
	local TableUtil = H.Module("Shared.Utilities.TableUtil")

	local function store(backend, sessionId, clock, temporary)
		return SessionLockedStore.new({
			Name = "Test",
			Template = ProfileTemplate,
			DataStore = backend,
			SessionId = sessionId,
			IsTemporary = temporary == true,
			StaleLockSeconds = 600,
			LoadAttempts = 2,
			LoadRetryDelay = 0,
			SaveAttempts = 2,
			Clock = clock,
			Wait = function() end,
		})
	end

	H.test("template matches the required schema", function()
		H.eq(ProfileTemplate.Version, Migrations.CurrentVersion, "template version must equal CurrentVersion")
		for _, key in { "TotalWaves", "TotalKills", "TotalHarvested", "BossesDefeated", "MatchesPlayed", "MatchesEscaped" } do
			H.eq(ProfileTemplate.Statistics[key], 0, key)
		end
		H.eq(ProfileTemplate.Settings.MusicEnabled, true)
		H.eq(ProfileTemplate.EquippedCostume, nil)
		H.ok(ProfileTemplate.UnlockedCostumes.Knight, "default class owned")
	end)

	H.test("migration 0 -> 1 converts legacy shapes", function()
		local legacy = { Candy = 300, UnlockedCostumes = { "Knight", "Witch" } }
		local ok = Migrations.Run(legacy)
		H.ok(ok)
		H.eq(legacy.Version, 1)
		H.eq(legacy.Candies, 300)
		H.eq(legacy.Candy, nil)
		H.ok(legacy.UnlockedCostumes.Witch == true and legacy.UnlockedCostumes.Knight == true)
		TableUtil.Reconcile(legacy, ProfileTemplate)
		H.eq(legacy.Statistics.TotalKills, 0, "reconcile adds missing keys after migration")
	end)

	H.test("profiles from a newer build are refused, not overwritten", function()
		local ok, reason = Migrations.Run({ Version = Migrations.CurrentVersion + 1 })
		H.ok(not ok)
		H.ok(reason ~= nil)
		H.ok(not (Migrations.Run({ Version = "x" })), "invalid version refused")
	end)

	H.test("session lock: a second server cannot load an active profile", function()
		local backend = SessionLockedStore.MemoryDataStore.new()
		local now = 1000
		local clock = function() return now end
		local serverA = store(backend, "A", clock)
		local serverB = store(backend, "B", clock)
		local profileA = serverA:LoadProfileAsync("Player_1", 1)
		H.ok(profileA, "A loads")
		H.eq(profileA.Data.Candies, ProfileTemplate.Candies)
		local profileB, problem = serverB:LoadProfileAsync("Player_1", 1)
		H.eq(profileB, nil)
		H.ok(problem and problem:find("another server"), tostring(problem))
	end)

	H.test("release saves data and lets the next server load it", function()
		local backend = SessionLockedStore.MemoryDataStore.new()
		local clock = function() return 1000 end
		local serverA = store(backend, "A", clock)
		local profileA = serverA:LoadProfileAsync("Player_2", 2)
		profileA.Data.Candies = 4321
		local released
		profileA:ListenToRelease(function(reason) released = reason end)
		profileA:ReleaseAsync()
		H.eq(released, "Released")
		H.ok(not profileA:IsActive())
		H.eq(profileA:SaveAsync(), false, "released profiles never save again")

		local profileB = store(backend, "B", clock):LoadProfileAsync("Player_2", 2)
		H.ok(profileB, "B loads after release")
		H.eq(profileB.Data.Candies, 4321)
		H.eq(backend:GetRaw("Player_2").MetaData.ActiveSession.SessionId, "B")
	end)

	H.test("stale locks from crashed servers are taken over", function()
		local backend = SessionLockedStore.MemoryDataStore.new()
		local now = 1000
		local clock = function() return now end
		local crashed = store(backend, "Crashed", clock)
		H.ok(crashed:LoadProfileAsync("Player_3", 3))
		now += 601
		local fresh = store(backend, "Fresh", clock)
		H.ok(fresh:LoadProfileAsync("Player_3", 3), "stale lock must be stealable")
	end)

	H.test("a server that lost its session never overwrites newer data", function()
		local backend = SessionLockedStore.MemoryDataStore.new()
		local now = 1000
		local clock = function() return now end
		local old = store(backend, "Old", clock)
		local oldProfile = old:LoadProfileAsync("Player_4", 4)
		now += 700
		local new = store(backend, "New", clock)
		local newProfile = new:LoadProfileAsync("Player_4", 4)
		newProfile.Data.Candies = 999
		H.ok(newProfile:SaveAsync())

		oldProfile.Data.Candies = 1
		local reason
		oldProfile:ListenToRelease(function(r) reason = r end)
		H.eq(oldProfile:SaveAsync(), false)
		H.eq(reason, "SessionStolen")
		H.eq(backend:GetRaw("Player_4").Data.Candies, 999, "stale server's write must be cancelled")
	end)

	H.test("autosave keeps the lock fresh", function()
		local backend = SessionLockedStore.MemoryDataStore.new()
		local now = 1000
		local clock = function() return now end
		local server = store(backend, "A", clock)
		local profile = server:LoadProfileAsync("Player_5", 5)
		now += 500
		H.ok(profile:SaveAsync())
		now += 500 -- 1000 s after load but only 500 s after the autosave
		H.eq((store(backend, "B", clock):LoadProfileAsync("Player_5", 5)), nil, "refreshed lock is not stale")
	end)

	H.test("temporary stores never write", function()
		local backend = SessionLockedStore.MemoryDataStore.new()
		local server = store(backend, "Mock", function() return 0 end, true)
		local profile = server:LoadProfileAsync("Player_6", 6)
		H.ok(profile and profile.IsTemporary)
		profile.Data.Candies = 50
		H.ok(profile:SaveAsync())
		profile:ReleaseAsync()
		H.eq(backend:GetRaw("Player_6"), nil)
	end)

	H.test("a profile cannot be loaded twice on the same server", function()
		local server = store(SessionLockedStore.MemoryDataStore.new(), "A", function() return 0 end)
		H.ok(server:LoadProfileAsync("Player_7", 7))
		H.eq((server:LoadProfileAsync("Player_7", 7)), nil)
	end)
end
