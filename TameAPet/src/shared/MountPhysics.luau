--!strict
-- Pure mount movement model: turns validated rider intent into a target velocity and
-- orientation. It has no Roblox side effects so it can be unit-tested outside the engine.
-- MountService feeds it the result of ground raycasts and applies the output to the
-- mount's LinearVelocity / AlignOrientation constraints.
--
-- Conventions: yaw 0 faces -Z (Roblox's default LookVector). Positive turn input = steer
-- right (clockwise seen from above). Speeds are studs/second.

export type Input = {
	forward: number, -- [-1, 1]
	turn: number, -- [-1, 1]
	vertical: number, -- [-1, 1] (flight only)
	jump: boolean,
}

export type Params = {
	speed: number,
	turnRate: number, -- radians/second
	airTurnRate: number,
	acceleration: number,
	deceleration: number,
	reverseFactor: number,
	canFly: boolean,
	canDoubleJump: boolean,
	ascendSpeed: number,
	descendSpeed: number,
	verticalAcceleration: number,
	jumpVelocity: number,
	doubleJumpVelocity: number,
	maxAirJumps: number,
	maxAltitude: number,
	landingHeight: number,
	bankAngle: number, -- radians
	pitchAngle: number, -- radians
}

export type Env = {
	grounded: boolean,
	heightAboveGround: number, -- math.huge when nothing is below
	flightAllowed: boolean,
	ceilingReached: boolean,
	verticalVelocity: number, -- measured, used while not flying
}

export type State = {
	yaw: number,
	forwardSpeed: number,
	verticalVelocity: number,
	flying: boolean,
	airJumpsUsed: number,
	jumpHeld: boolean,
}

export type Output = {
	flying: boolean,
	planarVelocity: Vector2, -- (X, Z) world velocity for ground mode
	velocity: Vector3, -- full world velocity for flight mode
	orientation: CFrame, -- rotation only
	jumpVelocity: number?, -- set vertical velocity to this once (ground jump)
}

local MountPhysics = {}

local TAU = math.pi * 2
local DEADZONE = 0.05

local function approach(current: number, target: number, maxDelta: number): number
	if current < target then
		return math.min(current + maxDelta, target)
	end
	return math.max(current - maxDelta, target)
end

local function axis(value: any): number
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	local clamped = math.clamp(value, -1, 1)
	if math.abs(clamped) < DEADZONE then
		return 0
	end
	-- Quantise so tiny float noise doesn't count as a "changed" input.
	return math.floor(clamped * 100 + 0.5) / 100
end

-- Untrusted values in, safe Input out. Anything malformed becomes "no input".
function MountPhysics.sanitizeInput(forward: any, turn: any, vertical: any, jump: any): Input
	return {
		forward = axis(forward),
		turn = axis(turn),
		vertical = axis(vertical),
		jump = jump == true,
	}
end

function MountPhysics.emptyInput(): Input
	return { forward = 0, turn = 0, vertical = 0, jump = false }
end

function MountPhysics.newState(yaw: number): State
	return {
		yaw = yaw,
		forwardSpeed = 0,
		verticalVelocity = 0,
		flying = false,
		airJumpsUsed = 0,
		jumpHeld = false,
	}
end

function MountPhysics.lookVector(yaw: number): Vector3
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

function MountPhysics.step(state: State, input: Input, params: Params, env: Env, dt: number): Output
	dt = math.clamp(dt, 0, 0.1)

	local jumpPressed = input.jump and not state.jumpHeld
	state.jumpHeld = input.jump

	-- Flight state transitions.
	if params.canFly then
		if state.flying then
			if not env.flightAllowed then
				state.flying = false
			elseif input.vertical < 0 and (env.grounded or env.heightAboveGround <= params.landingHeight) then
				state.flying = false -- touched down
			end
		elseif env.flightAllowed and input.vertical > 0 then
			state.flying = true
			state.verticalVelocity = math.max(env.verticalVelocity, 0)
		end
	else
		state.flying = false
	end

	-- Steering.
	local turnRate = if state.flying then params.airTurnRate else params.turnRate
	state.yaw = (state.yaw - input.turn * turnRate * dt) % TAU

	-- Forward speed along the heading (no sideways drift: arcade handling).
	local targetSpeed = if input.forward >= 0
		then input.forward * params.speed
		else input.forward * params.speed * params.reverseFactor
	local speedingUp = math.abs(targetSpeed) > math.abs(state.forwardSpeed)
		and math.sign(targetSpeed) ~= -math.sign(state.forwardSpeed)
	local rate = if speedingUp then params.acceleration else params.deceleration
	state.forwardSpeed = approach(state.forwardSpeed, targetSpeed, rate * dt)
	-- Never exceed the configured cap, whatever happened before.
	state.forwardSpeed = math.clamp(state.forwardSpeed, -params.speed * params.reverseFactor, params.speed)

	local look = MountPhysics.lookVector(state.yaw)
	local planar = look * state.forwardSpeed

	local jumpVelocity: number? = nil
	local pitch, roll = 0, 0

	if state.flying then
		local targetVy = if input.vertical > 0
			then input.vertical * params.ascendSpeed
			else input.vertical * params.descendSpeed
		if env.ceilingReached or env.heightAboveGround >= params.maxAltitude then
			targetVy = math.min(targetVy, if env.heightAboveGround > params.maxAltitude + 10 then -params.descendSpeed * 0.5 else 0)
		end
		state.verticalVelocity = approach(state.verticalVelocity, targetVy, params.verticalAcceleration * dt)
		state.airJumpsUsed = 0
		roll = -input.turn * params.bankAngle
		if params.ascendSpeed > 0 then
			pitch = math.clamp(state.verticalVelocity / params.ascendSpeed, -1, 1) * params.pitchAngle
		end
	else
		state.verticalVelocity = env.verticalVelocity
		if env.grounded then
			state.airJumpsUsed = 0
		end
		if jumpPressed then
			if env.grounded then
				jumpVelocity = params.jumpVelocity
			elseif params.canDoubleJump and state.airJumpsUsed < params.maxAirJumps then
				state.airJumpsUsed += 1
				jumpVelocity = params.doubleJumpVelocity
			end
		end
	end

	local orientation = CFrame.Angles(0, state.yaw, 0) * CFrame.Angles(pitch, 0, roll)
	local vy = if state.flying then state.verticalVelocity else 0

	return {
		flying = state.flying,
		planarVelocity = Vector2.new(planar.X, planar.Z),
		velocity = Vector3.new(planar.X, vy, planar.Z),
		orientation = orientation,
		jumpVelocity = jumpVelocity,
	}
end

return MountPhysics
