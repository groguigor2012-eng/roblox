--!strict
-- Pure movement math shared by the client controller and the server
-- validator. No Instances, no services: everything here is unit-tested
-- headlessly (platformer/tests).

local MovementConfig = require(script.Parent.Parent.Config.MovementConfig)

type CurveName = MovementConfig.CurveName

local MovementMath = {}

local EPSILON = 1e-4

local function clamp01(t: number): number
	if t ~= t then -- NaN
		return 0
	end
	return math.clamp(t, 0, 1)
end

-- Normalised progression curves. All satisfy curve(0) = 0, curve(1) = 1 and
-- are monotonic on [0, 1]. Input is clamped to [0, 1].
local CURVES: { [CurveName]: (number) -> number } = {
	Linear = function(t: number): number
		return t
	end,
	QuadOut = function(t: number): number
		return 1 - (1 - t) ^ 2
	end,
	CubicOut = function(t: number): number
		return 1 - (1 - t) ^ 3
	end,
	Smoothstep = function(t: number): number
		return t * t * (3 - 2 * t)
	end,
	ExpoOut = function(t: number): number
		if t >= 1 then
			return 1
		end
		return 1 - 2 ^ (-10 * t)
	end,
}

function MovementMath.IsCurveName(name: any): boolean
	return type(name) == "string" and CURVES[name :: CurveName] ~= nil
end

function MovementMath.EvaluateCurve(name: CurveName, t: number): number
	local curve = CURVES[name]
	if not curve then
		error(`unknown curve "{tostring(name)}"`, 2)
	end
	return curve(clamp01(t))
end

-- speed(t) = initial + (terminal - initial) * curve(t), t normalised to [0, 1].
function MovementMath.DashSpeed(initialSpeed: number, terminalSpeed: number, curve: CurveName, t: number): number
	return initialSpeed + (terminalSpeed - initialSpeed) * MovementMath.EvaluateCurve(curve, t)
end

-- v(d) = min(maxSpeed, initial + acceleration * d), d = seconds of descent (>= 0).
function MovementMath.DescentSpeed(initialSpeed: number, acceleration: number, maxSpeed: number, elapsed: number): number
	return math.min(maxSpeed, initialSpeed + acceleration * math.max(elapsed, 0))
end

-- Projects a vector onto the horizontal plane and normalises it. Returns nil
-- for (near-)vertical or zero vectors, so callers must handle the fallback.
function MovementMath.FlattenDirection(vector: Vector3): Vector3?
	local flat = Vector3.new(vector.X, 0, vector.Z)
	local magnitude = flat.Magnitude
	if magnitude < EPSILON or magnitude ~= magnitude then
		return nil
	end
	return flat / magnitude
end

-- Dash direction: movement input if any, else horizontal facing, else -Z.
-- Never includes camera pitch because both inputs are flattened.
function MovementMath.ResolveDashDirection(moveDirection: Vector3, lookVector: Vector3): Vector3
	return MovementMath.FlattenDirection(moveDirection)
		or MovementMath.FlattenDirection(lookVector)
		or Vector3.new(0, 0, -1)
end

-- A surface counts as a wall when its normal is mostly horizontal.
function MovementMath.IsWallNormal(normal: Vector3, maxNormalY: number): boolean
	return math.abs(normal.Y) <= maxNormalY and MovementMath.FlattenDirection(normal) ~= nil
end

-- launch = unit(flatNormal * horizontalWeight + up * verticalWeight) * speed
-- Direction comes from the wall's surface normal, never a fixed side vector.
function MovementMath.WallJumpVelocity(
	normal: Vector3,
	horizontalWeight: number,
	verticalWeight: number,
	speed: number
): Vector3
	local away = MovementMath.FlattenDirection(normal)
	if not away then
		return Vector3.new(0, speed, 0)
	end
	local direction = away * horizontalWeight + Vector3.new(0, verticalWeight, 0)
	if direction.Magnitude < EPSILON then
		return Vector3.new(0, speed, 0)
	end
	return direction.Unit * speed
end

-- Vertical take-off speed for a jump of the given height: v = sqrt(2 g h).
function MovementMath.JumpVelocityFromHeight(height: number, gravity: number): number
	return math.sqrt(2 * math.max(gravity, 0) * math.max(height, 0))
end

-- Distance from the HumanoidRootPart centre down to the feet.
--   R15: HipHeight + rootHeight / 2
--   R6:  rootHeight / 2 + legHeight   (R6 HipHeight is 0; the legs carry the height)
function MovementMath.FeetOffset(isR15: boolean, hipHeight: number, rootHeight: number, legHeight: number): number
	if isR15 then
		return hipHeight + rootHeight / 2
	end
	return rootHeight / 2 + legHeight
end

-- True when every component is a finite number (rejects NaN and +-inf).
function MovementMath.IsFiniteVector(vector: Vector3): boolean
	for _, component in { vector.X, vector.Y, vector.Z } do
		if component ~= component or component == math.huge or component == -math.huge then
			return false
		end
	end
	return true
end

return MovementMath
