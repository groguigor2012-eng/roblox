-- Mount movement model, speed formula and remote-security helpers.
local describe, it, expect = T.describe, T.it, T.expect

local MountPhysics = T.load("ReplicatedStorage/Shared/MountPhysics")
local MountStats = T.load("ServerScriptService/Services/MountStats")
local RateLimiter = T.load("ServerScriptService/Security/RateLimiter")
local Validate = T.load("ServerScriptService/Security/Validate")
local PetConfig = T.load("ReplicatedStorage/Config/PetConfig")
local MountConfig = T.load("ReplicatedStorage/Config/MountConfig")

local function params(overrides)
	local p = {
		speed = 60,
		turnRate = math.rad(140),
		airTurnRate = math.rad(110),
		acceleration = 70,
		deceleration = 110,
		reverseFactor = 0.4,
		canFly = false,
		canDoubleJump = false,
		ascendSpeed = 38,
		descendSpeed = 48,
		verticalAcceleration = 80,
		jumpVelocity = 55,
		doubleJumpVelocity = 48,
		maxAirJumps = 1,
		maxAltitude = 300,
		landingHeight = 1.5,
		bankAngle = math.rad(18),
		pitchAngle = math.rad(12),
	}
	for k, v in overrides or {} do
		p[k] = v
	end
	return p
end

local function env(overrides)
	local e = { grounded = true, heightAboveGround = 0, flightAllowed = true, ceilingReached = false, verticalVelocity = 0 }
	for k, v in overrides or {} do
		e[k] = v
	end
	return e
end

describe("MountStats", function()
	it("applies base speed, tier multiplier and upgrades, then clamps", function()
		local wolf = PetConfig.Species.EmberWolf
		expect(MountStats.computeSpeed(wolf, 0, MountConfig)).toBeNear(40 * 1.3, 1e-9)
		expect(MountStats.computeSpeed(wolf, 2, MountConfig)).toBeNear(40 * 1.3 * 1.12, 1e-9)
		local dragon = PetConfig.Species.CelestialDragon
		expect(MountStats.computeSpeed(dragon, 5, MountConfig)).toBe(MountConfig.MaxMountSpeed)
	end)
	it("derives flight from abilities", function()
		expect(MountStats.canFly(PetConfig.Species.SkyPegasus)).toBe(true)
		expect(MountStats.canFly(PetConfig.Species.EmberWolf)).toBe(false)
	end)
end)

describe("MountPhysics", function()
	it("sanitises malformed input", function()
		local input = MountPhysics.sanitizeInput(0 / 0, 1e9, "up", "yes")
		expect(input.forward).toBe(0)
		expect(input.turn).toBe(1)
		expect(input.vertical).toBe(0)
		expect(input.jump).toBe(false)
	end)
	it("accelerates smoothly and never exceeds the speed cap", function()
		local state = MountPhysics.newState(0)
		local p = params()
		local out
		for _ = 1, 600 do
			out = MountPhysics.step(state, MountPhysics.sanitizeInput(1, 0, 0, false), p, env(), 1 / 60)
			expect(out.planarVelocity.Magnitude).atMost(p.speed + 1e-6)
		end
		expect(out.planarVelocity.Magnitude).toBeNear(p.speed, 1e-6)
		-- facing -Z at yaw 0
		expect(out.planarVelocity.Y < 0).toBeTruthy()
	end)
	it("ignores huge dt spikes", function()
		local state = MountPhysics.newState(0)
		local out = MountPhysics.step(state, MountPhysics.sanitizeInput(1, 0, 0, false), params(), env(), 50)
		expect(out.planarVelocity.Magnitude).atMost(70 * 0.1 + 1e-6)
	end)
	it("steers right with positive turn input", function()
		local state = MountPhysics.newState(0)
		local out
		for _ = 1, 30 do
			out = MountPhysics.step(state, MountPhysics.sanitizeInput(1, 1, 0, false), params(), env(), 1 / 60)
		end
		expect(out.planarVelocity.X > 0).toBeTruthy()
	end)
	it("never lets a land mount fly", function()
		local state = MountPhysics.newState(0)
		for _ = 1, 120 do
			local out = MountPhysics.step(state, MountPhysics.sanitizeInput(1, 0, 1, true), params({ canFly = false }), env(), 1 / 60)
			expect(out.flying).toBe(false)
			expect(out.velocity.Y).toBe(0)
		end
	end)
	it("jumps only from the ground, with one air jump for DoubleJump pets", function()
		local p = params({ canDoubleJump = true })
		local state = MountPhysics.newState(0)
		local out = MountPhysics.step(state, MountPhysics.sanitizeInput(0, 0, 0, true), p, env(), 1 / 60)
		expect(out.jumpVelocity).toBe(p.jumpVelocity)
		MountPhysics.step(state, MountPhysics.sanitizeInput(0, 0, 0, false), p, env({ grounded = false, heightAboveGround = 5 }), 1 / 60)
		out = MountPhysics.step(state, MountPhysics.sanitizeInput(0, 0, 0, true), p, env({ grounded = false, heightAboveGround = 5 }), 1 / 60)
		expect(out.jumpVelocity).toBe(p.doubleJumpVelocity)
		MountPhysics.step(state, MountPhysics.sanitizeInput(0, 0, 0, false), p, env({ grounded = false, heightAboveGround = 5 }), 1 / 60)
		out = MountPhysics.step(state, MountPhysics.sanitizeInput(0, 0, 0, true), p, env({ grounded = false, heightAboveGround = 5 }), 1 / 60)
		expect(out.jumpVelocity).toBe(nil)
	end)
	it("takes off, climbs, respects the altitude cap and lands", function()
		local p = params({ canFly = true })
		local state = MountPhysics.newState(0)
		local out = MountPhysics.step(state, MountPhysics.sanitizeInput(0, 0, 1, true), p, env(), 1 / 60)
		expect(out.flying).toBe(true)
		for _ = 1, 120 do
			out = MountPhysics.step(state, MountPhysics.sanitizeInput(0, 0, 1, true), p, env({ grounded = false, heightAboveGround = 50 }), 1 / 60)
		end
		expect(out.velocity.Y).toBeNear(p.ascendSpeed, 1e-6)
		out = MountPhysics.step(state, MountPhysics.sanitizeInput(0, 0, 1, true), p, env({ grounded = false, heightAboveGround = 300 }), 1 / 60)
		expect(out.velocity.Y).atMost(p.ascendSpeed) -- decelerating toward 0
		for _ = 1, 120 do
			out = MountPhysics.step(state, MountPhysics.sanitizeInput(0, 0, 1, true), p, env({ grounded = false, heightAboveGround = 300 }), 1 / 60)
		end
		expect(out.velocity.Y).atMost(0)
		out = MountPhysics.step(state, MountPhysics.sanitizeInput(0, 0, -1, false), p, env({ grounded = true, heightAboveGround = 0.2 }), 1 / 60)
		expect(out.flying).toBe(false)
	end)
	it("forces a landing where flight is not allowed", function()
		local p = params({ canFly = true })
		local state = MountPhysics.newState(0)
		MountPhysics.step(state, MountPhysics.sanitizeInput(0, 0, 1, false), p, env(), 1 / 60)
		local out = MountPhysics.step(state, MountPhysics.sanitizeInput(0, 0, 1, false), p, env({ flightAllowed = false, grounded = false, heightAboveGround = 40 }), 1 / 60)
		expect(out.flying).toBe(false)
	end)
end)

describe("RateLimiter", function()
	it("allows `count` requests per sliding window", function()
		local now = 0
		local limiter = RateLimiter.new(function()
			return now
		end)
		local limit = { count = 3, window = 2 }
		expect(limiter:allow("p", "x", limit)).toBe(true)
		expect(limiter:allow("p", "x", limit)).toBe(true)
		expect(limiter:allow("p", "x", limit)).toBe(true)
		expect(limiter:allow("p", "x", limit)).toBe(false)
		expect(limiter:allow("p", "y", limit)).toBe(true) -- separate action
		now = 2.01
		expect(limiter:allow("p", "x", limit)).toBe(true)
	end)
end)

describe("Validate", function()
	it("accepts ids and rejects junk", function()
		local id = Validate.id(64)
		expect((id("BasicCompass"))).toBe(true)
		expect((id("8F2A-11"))).toBe(true)
		expect((id(""))).toBe(false)
		expect((id("../ServerStorage"))).toBe(false)
		expect((id(string.rep("a", 65)))).toBe(false)
		expect((id(42))).toBe(false)
		local _, cleaned = Validate.optionalId(64)(nil)
		expect(cleaned).toBe("")
	end)
	it("rejects non-finite numbers and clamps the rest", function()
		local v = Validate.clampedNumber(-1, 1)
		expect((v(0 / 0))).toBe(false)
		expect((v(math.huge))).toBe(false)
		local _, clamped = v(3)
		expect(clamped).toBe(1)
	end)
end)
