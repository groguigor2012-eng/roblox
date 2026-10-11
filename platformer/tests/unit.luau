--!nocheck
-- Unit tests for the framework's pure modules. Run via platformer/tests/run.sh.

local process = require("@lune/process")
local roblox = require("@lune/roblox")
local H = require("./harness")

local Vector3 = roblox.Vector3
local test, eq, near, truthy = H.test, H.eq, H.near, H.truthy

-- Vector3 components are 32-bit floats (as in Roblox).
local FLOAT32 = 1e-4

local MovementMath = H.load("shared/Math/MovementMath")
local HealthMath = H.load("shared/Math/HealthMath")
local MovementConfig = H.load("shared/Config/MovementConfig")
local DataConfig = H.load("shared/Config/DataConfig")
local DataSchema = H.load("server/Utilities/DataSchema")
local SessionLock = H.load("server/Utilities/SessionLock")
local DataStoreRetry = H.load("server/Utilities/DataStoreRetry")
local ProfileStore = H.load("server/Utilities/ProfileStore")
local MemoryDataStore = H.load("server/Utilities/MemoryDataStore")
local RateLimiter = H.load("server/Utilities/RateLimiter")
local ResourceCleanup = H.load("shared/Utilities/ResourceCleanup")

------------------------------------------------------------------------------
H.suite("MovementMath: curves and dash speed")

for _, curve in { "Linear", "QuadOut", "CubicOut", "Smoothstep", "ExpoOut" } do
	test(`{curve} maps 0->0, 1->1, is monotonic and clamps input`, function()
		near(MovementMath.EvaluateCurve(curve, 0), 0, 1e-9, "curve(0)")
		near(MovementMath.EvaluateCurve(curve, 1), 1, 1e-9, "curve(1)")
		local previous = -1
		for step = 0, 100 do
			local value = MovementMath.EvaluateCurve(curve, step / 100)
			truthy(value >= previous - 1e-12, `monotonic at {step}`)
			truthy(value >= 0 and value <= 1, `bounded at {step}`)
			previous = value
		end
		eq(MovementMath.EvaluateCurve(curve, -5), MovementMath.EvaluateCurve(curve, 0), "clamp low")
		eq(MovementMath.EvaluateCurve(curve, 7), MovementMath.EvaluateCurve(curve, 1), "clamp high")
		eq(MovementMath.EvaluateCurve(curve, 0 / 0), MovementMath.EvaluateCurve(curve, 0), "NaN -> 0")
	end)
end

test("unknown curve name errors", function()
	truthy(not pcall(MovementMath.EvaluateCurve, "Bogus", 0.5))
	truthy(not MovementMath.IsCurveName("Bogus"))
	truthy(MovementMath.IsCurveName(MovementConfig.Dash.Curve), "configured curve is valid")
end)

test("dash speed starts at InitialSpeed and ends at TerminalSpeed", function()
	local dash = MovementConfig.Dash
	near(MovementMath.DashSpeed(dash.InitialSpeed, dash.TerminalSpeed, dash.Curve, 0), dash.InitialSpeed, 1e-9)
	near(MovementMath.DashSpeed(dash.InitialSpeed, dash.TerminalSpeed, dash.Curve, 1), dash.TerminalSpeed, 1e-9)
	-- QuadOut at t = 0.5: 95 + (34 - 95) * 0.75 = 49.25
	near(MovementMath.DashSpeed(95, 34, "QuadOut", 0.5), 49.25, 1e-9, "QuadOut midpoint")
	near(MovementMath.DashSpeed(95, 34, "Linear", 0.5), 64.5, 1e-9, "Linear midpoint")
end)

test("descent speed accelerates and caps", function()
	eq(MovementMath.DescentSpeed(60, 400, 140, 0), 60)
	eq(MovementMath.DescentSpeed(60, 400, 140, 0.1), 100)
	eq(MovementMath.DescentSpeed(60, 400, 140, 5), 140)
	eq(MovementMath.DescentSpeed(60, 400, 140, -1), 60, "negative time clamps")
end)

------------------------------------------------------------------------------
H.suite("MovementMath: directions and walls")

test("dash direction prefers movement input, flattened", function()
	local direction = MovementMath.ResolveDashDirection(Vector3.new(3, 5, 4), Vector3.new(1, 0, 0))
	near(direction.X, 0.6, FLOAT32)
	near(direction.Y, 0, FLOAT32)
	near(direction.Z, 0.8, FLOAT32)
end)

test("dash direction falls back to facing, ignoring pitch", function()
	local direction = MovementMath.ResolveDashDirection(Vector3.new(0, 0, 0), Vector3.new(0, -0.9, -0.1))
	near(direction.Magnitude, 1, FLOAT32)
	near(direction.Z, -1, FLOAT32)
	near(direction.Y, 0, FLOAT32)
end)

test("dash direction survives zero input and vertical facing", function()
	local direction = MovementMath.ResolveDashDirection(Vector3.new(0, 0, 0), Vector3.new(0, 1, 0))
	eq(direction, Vector3.new(0, 0, -1))
end)

test("wall normals: walls accepted, floors and ceilings rejected", function()
	local maxY = MovementConfig.WallJump.MaxWallNormalY
	truthy(MovementMath.IsWallNormal(Vector3.new(1, 0, 0), maxY), "vertical wall")
	truthy(MovementMath.IsWallNormal(Vector3.new(0.95, 0.3, 0).Unit, maxY), "slightly sloped wall")
	truthy(not MovementMath.IsWallNormal(Vector3.new(0, 1, 0), maxY), "floor")
	truthy(not MovementMath.IsWallNormal(Vector3.new(0, -1, 0), maxY), "ceiling")
	truthy(not MovementMath.IsWallNormal(Vector3.new(0.5, 0.86, 0).Unit, maxY), "steep floor")
end)

test("wall jump pushes away from the surface normal with an upward component", function()
	for _, normal in { Vector3.new(1, 0, 0), Vector3.new(0, 0, -1), Vector3.new(-0.6, 0.1, 0.8).Unit } do
		local velocity = MovementMath.WallJumpVelocity(normal, 1, 1.25, 62)
		near(velocity.Magnitude, 62, FLOAT32, "speed")
		truthy(velocity.Y > 0, "upward")
		local flatNormal = Vector3.new(normal.X, 0, normal.Z).Unit
		local flatVelocity = Vector3.new(velocity.X, 0, velocity.Z).Unit
		near(flatVelocity:Dot(flatNormal), 1, FLOAT32, "horizontal part along normal")
		near(velocity.Y / Vector3.new(velocity.X, 0, velocity.Z).Magnitude, 1.25, FLOAT32, "weight ratio")
	end
end)

test("wall jump with a degenerate normal goes straight up", function()
	eq(MovementMath.WallJumpVelocity(Vector3.new(0, 1, 0), 1, 1, 10), Vector3.new(0, 10, 0))
end)

test("feet offset for R15 and R6", function()
	eq(MovementMath.FeetOffset(true, 2, 2, 0), 3)
	eq(MovementMath.FeetOffset(false, 0, 2, 2), 3)
end)

test("finite vector check", function()
	truthy(MovementMath.IsFiniteVector(Vector3.new(1, 2, 3)))
	truthy(not MovementMath.IsFiniteVector(Vector3.new(0 / 0, 0, 0)))
	truthy(not MovementMath.IsFiniteVector(Vector3.new(math.huge, 0, 0)))
end)

test("jump velocity from height", function()
	near(MovementMath.JumpVelocityFromHeight(7.2, 196.2), math.sqrt(2 * 196.2 * 7.2), 1e-9)
	eq(MovementMath.JumpVelocityFromHeight(-1, 196.2), 0)
end)

------------------------------------------------------------------------------
H.suite("MovementMath: double-jump spin and float")

test("spin profile eases in and out", function()
	near(MovementMath.SpinProfile(0), 0, 1e-9, "start")
	near(MovementMath.SpinProfile(0.5), 1, 1e-9, "peak")
	near(MovementMath.SpinProfile(1), 0, 1e-9, "end")
	eq(MovementMath.SpinProfile(-1), MovementMath.SpinProfile(0), "clamped")
	-- Total turn = SpinSpeed * duration * 2/pi; integrate numerically.
	local spin = MovementConfig.SpinFloat
	local steps, total = 2000, 0
	for index = 0, steps - 1 do
		local s = (index + 0.5) / steps
		total += spin.SpinSpeed * MovementMath.SpinProfile(s) * (spin.SpinDuration / steps)
	end
	near(total, spin.SpinSpeed * spin.SpinDuration * 2 / math.pi, 0.01, "total degrees")
	truthy(total >= 300 and total <= 420, "default spin is about one full turn")
end)

test("float fade holds, then drops linearly to zero, and closes", function()
	eq(MovementMath.FloatFade(0, 0.9, 0.25), 1)
	eq(MovementMath.FloatFade(0.6, 0.9, 0.25), 1)
	near(MovementMath.FloatFade(0.775, 0.9, 0.25), 0.5, 1e-9)
	eq(MovementMath.FloatFade(0.9, 0.9, 0.25), 0, "window closed")
	eq(MovementMath.FloatFade(5, 0.9, 0.25), 0, "never floats forever")
	eq(MovementMath.FloatFade(-0.1, 0.9, 0.25), 0)
	eq(MovementMath.FloatFade(0.5, 0.9, 0), 1, "no fade time")
end)

test("float lift leaves the configured fraction of gravity", function()
	-- mass 10, g 196.2, scale 0.35 -> lift cancels 65% of weight.
	near(MovementMath.FloatLiftForce(10, 196.2, 0.35, 1), 10 * 196.2 * 0.65, 1e-9)
	near(MovementMath.FloatLiftForce(10, 196.2, 0.35, 0.5), 10 * 196.2 * 0.325, 1e-9)
	eq(MovementMath.FloatLiftForce(10, 196.2, 1, 1), 0, "scale 1 = no float")
	near(MovementMath.FloatLiftForce(10, 196.2, -3, 1), 10 * 196.2, 1e-9, "scale clamped: never more than weight")
	near(MovementMath.FloatLiftForce(10, 196.2, 0.35, 7), 10 * 196.2 * 0.65, 1e-9, "fade clamped")
end)

------------------------------------------------------------------------------
H.suite("AttackMath")

local AttackMath = H.load("shared/Math/AttackMath")
local CombatConfigForTests = H.load("shared/Config/CombatConfig")

test("fallback punch is continuous, hits the strike pose and ends neutral", function()
	local pose = CombatConfigForTests.Attack.Fallback
	local total = AttackMath.TotalTime(pose)
	local previous = { AttackMath.FallbackPose(pose, 0) }
	eq(previous[1], 0, "starts neutral")
	local reachedStrike, reachedWindup = false, false
	for index = 1, 400 do
		local elapsed = total * index / 400
		local pitch, bend, twist, finished = AttackMath.FallbackPose(pose, elapsed)
		if not finished then
			truthy(math.abs(pitch - previous[1]) < 25, `no shoulder jump at {elapsed}`)
			truthy(math.abs(bend - previous[2]) < 25, `no elbow jump at {elapsed}`)
			truthy(math.abs(twist - previous[3]) < 10, `no waist jump at {elapsed}`)
		end
		if math.abs(pitch - pose.StrikeShoulderPitch) < 1e-6 then
			reachedStrike = true
		end
		if math.abs(pitch - pose.WindupShoulderPitch) < 1 then
			reachedWindup = true
		end
		previous = { pitch, bend, twist }
	end
	truthy(reachedWindup, "wind-up reached")
	truthy(reachedStrike, "strike held")
	local pitch, bend, twist, finished = AttackMath.FallbackPose(pose, total + 0.01)
	truthy(finished, "finishes")
	eq(pitch, 0)
	eq(bend, 0)
	eq(twist, 0)
end)

test("click versus camera drag", function()
	truthy(AttackMath.IsClick(0.1, 2, 0.3, 8), "short still click")
	truthy(not AttackMath.IsClick(0.5, 0, 0.3, 8), "held too long")
	truthy(not AttackMath.IsClick(0.1, 40, 0.3, 8), "dragged the camera")
end)

------------------------------------------------------------------------------
H.suite("HealthMath")

local function hearts(health, maxHealth)
	return HealthMath.HeartsFromHealth(health, maxHealth or 100, 3)
end

test("full and boundary values for 100 HP / 3 hearts", function()
	eq(hearts(100), 3, "100")
	eq(hearts(66.67), 3, "66.67")
	eq(hearts(200 / 3), 2, "exactly 66.666...")
	eq(hearts(66.66), 2, "66.66")
	eq(hearts(33.34), 2, "33.34")
	eq(hearts(100 / 3), 1, "exactly 33.333...")
	eq(hearts(33.33), 1, "33.33")
	eq(hearts(0.01), 1, "0.01")
	eq(hearts(0), 0, "0")
end)

test("invalid inputs never error or divide by zero", function()
	eq(hearts(-10), 0, "negative")
	eq(hearts(0 / 0), 0, "NaN health")
	eq(hearts(150), 3, "overheal clamps")
	eq(hearts(50, 0), 3, "MaxHealth 0 with health")
	eq(hearts(0, 0), 0, "MaxHealth 0 without health")
	eq(hearts(50, math.huge), 3, "infinite MaxHealth")
	eq(HealthMath.HeartsFromHealth(50, 100, 0), 0, "zero hearts configured")
end)

test("changed MaxHealth rescales hearts", function()
	eq(hearts(100, 300), 1)
	eq(hearts(250, 300), 3)
	eq(hearts(150, 300), 2)
end)

------------------------------------------------------------------------------
H.suite("DataSchema")

test("nil is a new player with defaults", function()
	local data, report = DataSchema.Normalize(nil)
	eq(report.Status, "New")
	eq(data.Shards, 0)
	eq(data.PowerOrbs, 0)
	eq(data.SchemaVersion, DataConfig.SchemaVersion)
	eq(next(data.CollectedCollectibles), nil)
end)

test("valid data is Ok and unchanged", function()
	local data, report = DataSchema.Normalize({
		SchemaVersion = 1,
		Shards = 12,
		PowerOrbs = 3,
		CollectedCollectibles = { ["a.1"] = true, ["b-2"] = true },
	})
	eq(report.Status, "Ok")
	eq(#report.Issues, 0)
	eq(data.Shards, 12)
	eq(data.PowerOrbs, 3)
	truthy(data.CollectedCollectibles["a.1"] and data.CollectedCollectibles["b-2"])
end)

test("malformed fields are repaired without discarding valid ones", function()
	local data, report = DataSchema.Normalize({
		SchemaVersion = 1,
		Shards = -5,
		PowerOrbs = 7.8,
		CollectedCollectibles = { ["good"] = true, ["bad id!"] = true, ["off"] = false, [""] = true },
		Junk = "x",
	})
	eq(report.Status, "Repaired")
	eq(data.Shards, 0, "negative -> 0")
	eq(data.PowerOrbs, 7, "fraction floored")
	truthy(data.CollectedCollectibles.good, "valid id kept")
	eq(data.CollectedCollectibles["bad id!"], nil)
	eq(data.CollectedCollectibles.off, nil)
	eq(data.Junk, nil, "unknown field dropped")
end)

test("non-number and huge currency values", function()
	local data = DataSchema.Normalize({ SchemaVersion = 1, Shards = "12", PowerOrbs = 1e300, CollectedCollectibles = {} })
	eq(data.Shards, 0)
	eq(data.PowerOrbs, DataConfig.MaxCurrency)
	local nanData = DataSchema.Normalize({ SchemaVersion = 1, Shards = 0 / 0, PowerOrbs = 1, CollectedCollectibles = {} })
	eq(nanData.Shards, 0)
end)

test("array-form collected ids are converted", function()
	local data, report = DataSchema.Normalize({ SchemaVersion = 1, Shards = 0, PowerOrbs = 0, CollectedCollectibles = { "x", "y", "x" } })
	truthy(data.CollectedCollectibles.x and data.CollectedCollectibles.y)
	eq(report.Status, "Repaired", "duplicate reported")
end)

test("version 0 (unversioned) migrates Orbs and Collected", function()
	local data, report = DataSchema.Normalize({ Shards = 4, Orbs = 2, Collected = { "demo.1", "demo.2" } })
	eq(report.MigratedFrom, 0)
	eq(data.SchemaVersion, 1)
	eq(data.PowerOrbs, 2)
	eq(data.Shards, 4)
	truthy(data.CollectedCollectibles["demo.1"] and data.CollectedCollectibles["demo.2"])
end)

test("future schema is refused", function()
	local _, report = DataSchema.Normalize({ SchemaVersion = DataConfig.SchemaVersion + 1, Shards = 5 })
	eq(report.Status, "FutureSchema")
end)

test("non-table value is Corrupt", function()
	local data, report = DataSchema.Normalize("garbage")
	eq(report.Status, "Corrupt")
	eq(data.Shards, 0)
end)

test("collected id cap is enforced deterministically", function()
	local ids = {}
	for index = 1, DataConfig.MaxCollectedIds + 5 do
		ids[string.format("id%06d", index)] = true
	end
	local data, report = DataSchema.Normalize({ SchemaVersion = 1, Shards = 0, PowerOrbs = 0, CollectedCollectibles = ids })
	local count = 0
	for _ in data.CollectedCollectibles do
		count += 1
	end
	eq(count, DataConfig.MaxCollectedIds)
	eq(report.Status, "Repaired")
	truthy(data.CollectedCollectibles.id000001, "lowest ids kept")
end)

test("Copy is deep", function()
	local data = DataSchema.Default()
	local copy = DataSchema.Copy(data)
	copy.CollectedCollectibles.x = true
	copy.Shards = 9
	eq(data.CollectedCollectibles.x, nil)
	eq(data.Shards, 0)
end)

test("collectible id validation", function()
	truthy(DataSchema.IsValidCollectibleId("demo.ring.01"))
	truthy(DataSchema.IsValidCollectibleId("a_b-c:d"))
	truthy(not DataSchema.IsValidCollectibleId(""))
	truthy(not DataSchema.IsValidCollectibleId("has space"))
	truthy(not DataSchema.IsValidCollectibleId(string.rep("a", 65)))
	truthy(not DataSchema.IsValidCollectibleId(42))
end)

------------------------------------------------------------------------------
H.suite("SessionLock")

test("lock states", function()
	eq(SessionLock.Evaluate(nil, "A", 1000, 300), "Free")
	eq(SessionLock.Evaluate({ JobId = "" , LockedAt = 1 }, "A", 1000, 300), "Free", "invalid session")
	eq(SessionLock.Evaluate({ JobId = "A", LockedAt = 1 }, "A", 1000, 300), "Owned", "own lock even if old")
	eq(SessionLock.Evaluate({ JobId = "B", LockedAt = 900 }, "A", 1000, 300), "HeldByOther")
	eq(SessionLock.Evaluate({ JobId = "B", LockedAt = 600 }, "A", 1000, 300), "Expired")
	eq(SessionLock.Evaluate({ JobId = "B", LockedAt = 1100 }, "A", 1000, 300), "HeldByOther", "clock skew")
end)

------------------------------------------------------------------------------
H.suite("DataStoreRetry")

local function retryOptions(sleeps)
	return {
		MaxAttempts = 4,
		BaseDelay = 0.5,
		MaxDelay = 3,
		JitterFraction = 0.5,
		Sleep = function(seconds)
			table.insert(sleeps, seconds)
		end,
		Random = function()
			return 0
		end,
	}
end

test("exponential backoff with cap and jitter", function()
	local options = retryOptions({})
	eq(DataStoreRetry.ComputeDelay(1, options, 0), 0.5)
	eq(DataStoreRetry.ComputeDelay(2, options, 0), 1)
	eq(DataStoreRetry.ComputeDelay(3, options, 0), 2)
	eq(DataStoreRetry.ComputeDelay(4, options, 0), 3, "capped")
	eq(DataStoreRetry.ComputeDelay(1, options, 1), 0.75, "full jitter")
end)

test("transient failures are retried until success", function()
	local sleeps = {}
	local calls = 0
	local ok, value, attempts = DataStoreRetry.Run("op", function()
		calls += 1
		if calls < 3 then
			error("502: API Services rejected request", 0)
		end
		return "done"
	end, retryOptions(sleeps))
	eq(ok, true)
	eq(value, "done")
	eq(attempts, 3)
	eq(#sleeps, 2)
	eq(sleeps[1], 0.5)
	eq(sleeps[2], 1)
end)

test("non-retryable errors fail immediately", function()
	local sleeps = {}
	for _, message in { "104: Cannot store Instance", "403: Cannot write", "StudioAccessToApisNotAllowed" } do
		local ok, err, attempts = DataStoreRetry.Run("op", function()
			error(message, 0)
		end, retryOptions(sleeps))
		eq(ok, false)
		eq(attempts, 1, message)
		truthy(string.find(err, message, 1, true), "error text kept")
	end
	eq(#sleeps, 0)
end)

test("retries are bounded", function()
	local sleeps = {}
	local ok, _, attempts = DataStoreRetry.Run("op", function()
		error("301: throttled", 0)
	end, retryOptions(sleeps))
	eq(ok, false)
	eq(attempts, 4)
	eq(#sleeps, 3)
end)

------------------------------------------------------------------------------
H.suite("ProfileStore + MemoryDataStore (session locking)")

local clock = 10000
local function options(jobId)
	return {
		JobId = jobId,
		PlaceId = 1,
		LockTimeout = 300,
		Now = function()
			return clock
		end,
		Retry = {
			MaxAttempts = 3,
			BaseDelay = 0,
			MaxDelay = 0,
			JitterFraction = 0,
			Sleep = function() end,
		},
	}
end

local KEY = "Player_1"

local function dataWith(shards)
	local data = DataSchema.Default()
	data.Shards = shards
	return data
end

test("new player is acquired and locked by this server", function()
	local store = MemoryDataStore.new()
	local result = ProfileStore.Acquire(store, KEY, 1, options("A"))
	eq(result.Status, "Acquired")
	eq(result.Report.Status, "New")
	local record = store:GetRaw(KEY)
	eq(record.Session.JobId, "A")
	eq(record.Data.Shards, 0)
end)

test("a second live server cannot acquire or write", function()
	local store = MemoryDataStore.new()
	ProfileStore.Acquire(store, KEY, 1, options("A"))
	local second = ProfileStore.Acquire(store, KEY, 1, options("B"))
	eq(second.Status, "Locked")
	eq(second.LockHolder, "A")
	local write = ProfileStore.Write(store, KEY, 1, dataWith(999), false, options("B"))
	eq(write.Status, "LostLock")
	eq(store:GetRaw(KEY).Data.Shards, 0, "B's write did not land")
end)

test("owner saves and refreshes the lock", function()
	local store = MemoryDataStore.new()
	ProfileStore.Acquire(store, KEY, 1, options("A"))
	clock += 100
	local write = ProfileStore.Write(store, KEY, 1, dataWith(5), false, options("A"))
	eq(write.Status, "Saved")
	local record = store:GetRaw(KEY)
	eq(record.Data.Shards, 5)
	eq(record.Session.LockedAt, clock, "lock refreshed")
end)

test("expired lock is taken over and the stale server can no longer save", function()
	local store = MemoryDataStore.new()
	ProfileStore.Acquire(store, KEY, 1, options("A"))
	ProfileStore.Write(store, KEY, 1, dataWith(7), false, options("A"))
	clock += 301
	local takeover = ProfileStore.Acquire(store, KEY, 1, options("B"))
	eq(takeover.Status, "Acquired")
	eq(takeover.TookExpiredLock, true)
	eq(takeover.Data.Shards, 7, "B sees A's last save")
	local stale = ProfileStore.Write(store, KEY, 1, dataWith(1), false, options("A"))
	eq(stale.Status, "LostLock")
	eq(store:GetRaw(KEY).Data.Shards, 7, "stale write rejected")
end)

test("release clears the lock so the next server acquires immediately", function()
	local store = MemoryDataStore.new()
	ProfileStore.Acquire(store, KEY, 1, options("A"))
	local release = ProfileStore.Write(store, KEY, 1, dataWith(3), true, options("A"))
	eq(release.Status, "Saved")
	eq(store:GetRaw(KEY).Session, nil)
	local next = ProfileStore.Acquire(store, KEY, 1, options("B"))
	eq(next.Status, "Acquired")
	eq(next.TookExpiredLock, false)
	eq(next.Data.Shards, 3)
end)

test("release whose response was lost is not misreported", function()
	local store = MemoryDataStore.new()
	ProfileStore.Acquire(store, KEY, 1, options("A"))
	store:QueueFailure("502: response lost", true)
	local release = ProfileStore.Write(store, KEY, 1, dataWith(4), true, options("A"))
	eq(release.Status, "Saved")
	eq(store:GetRaw(KEY).Data.Shards, 4)
	eq(store:GetRaw(KEY).Session, nil)
end)

test("transient DataStore errors are retried; exhaustion leaves data untouched", function()
	local store = MemoryDataStore.new()
	ProfileStore.Acquire(store, KEY, 1, options("A"))
	ProfileStore.Write(store, KEY, 1, dataWith(10), false, options("A"))
	store:QueueFailure("502: busy")
	eq(ProfileStore.Write(store, KEY, 1, dataWith(11), false, options("A")).Status, "Saved")
	for _ = 1, 3 do
		store:QueueFailure("502: busy")
	end
	local failed = ProfileStore.Write(store, KEY, 1, dataWith(99), false, options("A"))
	eq(failed.Status, "Failed")
	eq(store:GetRaw(KEY).Data.Shards, 11)
end)

test("load failure reports Failed and never writes defaults", function()
	local store = MemoryDataStore.new()
	store:SetRaw(KEY, { FormatVersion = 1, Data = { SchemaVersion = 1, Shards = 50, PowerOrbs = 2, CollectedCollectibles = {} } })
	for _ = 1, 3 do
		store:QueueFailure("502: unavailable")
	end
	local result = ProfileStore.Acquire(store, KEY, 1, options("A"))
	eq(result.Status, "Failed")
	eq(store:GetRaw(KEY).Data.Shards, 50, "existing data intact")
	eq(store:GetRaw(KEY).Session, nil, "no lock taken")
end)

test("legacy bare record is wrapped, migrated and repaired on acquire", function()
	local store = MemoryDataStore.new()
	store:SetRaw(KEY, { Shards = 8, Orbs = 1, Collected = { "x.1" } })
	local result = ProfileStore.Acquire(store, KEY, 1, options("A"))
	eq(result.Status, "Acquired")
	eq(result.Report.MigratedFrom, 0)
	local record = store:GetRaw(KEY)
	eq(record.FormatVersion, 1)
	eq(record.Data.PowerOrbs, 1)
	eq(record.Data.CollectedCollectibles["x.1"], true)
end)

test("future-schema record is left untouched and unlocked", function()
	local store = MemoryDataStore.new()
	store:SetRaw(KEY, { FormatVersion = 1, Data = { SchemaVersion = 99, Shards = 1 } })
	local result = ProfileStore.Acquire(store, KEY, 1, options("A"))
	eq(result.Status, "FutureSchema")
	local record = store:GetRaw(KEY)
	eq(record.Data.SchemaVersion, 99)
	eq(record.Session, nil)
end)

test("Instances cannot be stored (serialisation guard)", function()
	local store = MemoryDataStore.new()
	truthy(not pcall(function()
		store:SetRaw(KEY, { Bad = Vector3.new(1, 2, 3) })
	end))
end)

------------------------------------------------------------------------------
H.suite("RateLimiter")

test("burst capacity then refill over time", function()
	local now = 0
	local limiter = RateLimiter.new(3, 2, function()
		return now
	end)
	truthy(limiter:Allow("p"))
	truthy(limiter:Allow("p"))
	truthy(limiter:Allow("p"))
	truthy(not limiter:Allow("p"), "bucket empty")
	truthy(limiter:Allow("q"), "keys are independent")
	now = 0.5
	truthy(limiter:Allow("p"), "one token after 0.5 s at 2/s")
	truthy(not limiter:Allow("p"))
	now = 100
	for _ = 1, 3 do
		truthy(limiter:Allow("p"))
	end
	truthy(not limiter:Allow("p"), "refill capped at capacity")
	limiter:Remove("p")
	truthy(limiter:Allow("p"), "removed key starts full")
end)

------------------------------------------------------------------------------
H.suite("ResourceCleanup")

test("releases in reverse order and keeps going after an error", function()
	local order = {}
	local cleanup = ResourceCleanup.new("test")
	cleanup:Add(function()
		table.insert(order, 1)
	end)
	cleanup:Add(function()
		error("boom")
	end)
	cleanup:Add({
		Destroy = function()
			table.insert(order, 3)
		end,
	})
	H.takeWarnings()
	cleanup:Clean()
	eq(order[1], 3)
	eq(order[2], 1)
	local warnings = H.takeWarnings()
	eq(#warnings, 1, "error reported, not swallowed")
	truthy(string.find(warnings[1], "boom", 1, true))
end)

test("Clean is reusable; Destroy releases late additions immediately", function()
	local count = 0
	local cleanup = ResourceCleanup.new("test")
	cleanup:Add(function()
		count += 1
	end)
	cleanup:Clean()
	cleanup:Clean()
	eq(count, 1, "released once")
	cleanup:Destroy()
	truthy(cleanup:IsDestroyed())
	cleanup:Add(function()
		count += 1
	end)
	eq(count, 2, "late add released immediately")
end)

test("unsupported resources are reported", function()
	local cleanup = ResourceCleanup.new("test")
	cleanup:Add(42)
	H.takeWarnings()
	cleanup:Clean()
	eq(#H.takeWarnings(), 1)
end)

------------------------------------------------------------------------------
H.suite("Config invariants")

local CollectibleConfig = H.load("shared/Config/CollectibleConfig")
local GameConfig = H.load("shared/Config/GameConfig")
local HealthUIConfig = H.load("shared/Config/HealthUIConfig")

test("data timing: a live server always refreshes its lock before it expires", function()
	truthy(DataConfig.Session.LockTimeout > DataConfig.LockRefreshAge + DataConfig.AutosaveInterval)
	truthy(DataConfig.ShutdownTimeout < 30, "BindToClose budget is 30 s")
	truthy(DataConfig.Retry.MaxAttempts >= 1 and DataConfig.Retry.BaseDelay <= DataConfig.Retry.MaxDelay)
end)

test("rewards fit inside a single grant and the currency cap", function()
	truthy(CollectibleConfig.MaxRewardAmount <= DataConfig.MaxSingleGrant)
	truthy(DataConfig.MaxSingleGrant <= DataConfig.MaxCurrency)
	for _, currency in { "Shards", "PowerOrbs" } do
		local reward = CollectibleConfig.DefaultRewards[currency]
		truthy(reward and reward >= 1 and reward == math.floor(reward), `default reward for {currency}`)
		truthy(CollectibleConfig.Visual.Colors[currency] and CollectibleConfig.Visual.DisplayNames[currency], `visuals for {currency}`)
	end
end)

test("server accepts every pickup the client may request", function()
	local collection = CollectibleConfig.Collection
	truthy(collection.ServerCollectRadius >= collection.ClientCollectRadius)
	truthy(collection.RequestTimeout > collection.ClientCheckInterval)
end)

test("movement tuning is coherent", function()
	local dash, pound, wall = MovementConfig.Dash, MovementConfig.GroundPound, MovementConfig.WallJump
	truthy(dash.Cooldown >= dash.Duration, "dash cannot overlap itself")
	truthy(dash.Cooldown > MovementConfig.Validation.CooldownTolerance, "server tolerance below cooldown")
	truthy(wall.Cooldown > MovementConfig.Validation.CooldownTolerance)
	truthy(pound.InitialDescentSpeed <= pound.MaxDescentSpeed)
	truthy(pound.MinActivationHeight > MovementConfig.Validation.ActivationHeightTolerance)
	truthy(wall.ProbeDirections >= 4 and #wall.ProbeHeightOffsets >= 1)
	truthy(wall.MaxWallNormalY < 0.7, "floors (normal Y ~ 1) are never walls")
end)

test("spin-float and attack tuning are coherent", function()
	local spin = MovementConfig.SpinFloat
	truthy(spin.FallGravityScale > 0 and spin.FallGravityScale <= 1, "gravity never fully cancelled")
	truthy(spin.FloatFadeTime <= spin.FloatDuration)
	truthy(spin.SpinDuration > 0 and spin.FloatDuration > 0 and spin.UpwardBoost >= 0)
	truthy(spin.SpinDirection == 1 or spin.SpinDirection == -1)
	local attack = H.load("shared/Config/CombatConfig").Attack
	local AttackMathModule = H.load("shared/Math/AttackMath")
	truthy(attack.Cooldown >= AttackMathModule.TotalTime(attack.Fallback), "fallback punch cannot overlap itself")
	truthy(attack.TriggerMode == "Click" or attack.TriggerMode == "Press")
	truthy(attack.BlockedStates.Dead, "never attacks while dead")
end)

test("hearts and remotes", function()
	truthy(HealthUIConfig.HeartCount >= 1)
	truthy(GameConfig.Health.MaxHealth > 0)
	for name, className in GameConfig.Remotes do
		eq(className, "RemoteEvent", name)
	end
end)

process.exit(if H.summary() == 0 then 0 else 1)
