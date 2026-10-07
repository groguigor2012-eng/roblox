--!strict
--[[
	MathUtil
	Path: ReplicatedStorage.Shared.Utilities.MathUtil

	Small geometry helpers used by AI, placement validation and combat.

	API:
		Flat(v) -> Vector3                        -- zeroes Y
		FlatDistance(a, b) -> number
		FlatDirection(from, to) -> Vector3        -- unit, Y=0 (zero vector when equal)
		AngleBetweenFlat(a, b) -> number          -- degrees between two directions on XZ
		BallisticVelocity(from, to, flightTime, gravity) -> Vector3
		SampleBallistic(origin, velocity, gravity, t) -> Vector3
		Lerp(a, b, t) -> number
		InverseLerp(a, b, v) -> number            -- clamped 0..1
		RoundTo(value, step) -> number
]]

local MathUtil = {}

function MathUtil.Flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

function MathUtil.FlatDistance(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

function MathUtil.FlatDirection(from: Vector3, to: Vector3): Vector3
	local delta = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if delta.Magnitude < 1e-4 then
		return Vector3.zero
	end
	return delta.Unit
end

function MathUtil.AngleBetweenFlat(a: Vector3, b: Vector3): number
	local fa, fb = MathUtil.Flat(a), MathUtil.Flat(b)
	if fa.Magnitude < 1e-4 or fb.Magnitude < 1e-4 then
		return 0
	end
	local dot = math.clamp(fa.Unit:Dot(fb.Unit), -1, 1)
	return math.deg(math.acos(dot))
end

-- Initial velocity that carries a projectile from `from` to `to` in exactly
-- `flightTime` seconds under constant downward `gravity`.
function MathUtil.BallisticVelocity(from: Vector3, to: Vector3, flightTime: number, gravity: number): Vector3
	local t = math.max(flightTime, 0.05)
	local delta = to - from
	local horizontal = Vector3.new(delta.X, 0, delta.Z) / t
	local vertical = (delta.Y + 0.5 * gravity * t * t) / t
	return horizontal + Vector3.new(0, vertical, 0)
end

function MathUtil.SampleBallistic(origin: Vector3, velocity: Vector3, gravity: number, t: number): Vector3
	return origin + velocity * t + Vector3.new(0, -0.5 * gravity * t * t, 0)
end

function MathUtil.Lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function MathUtil.InverseLerp(a: number, b: number, v: number): number
	if a == b then
		return 0
	end
	return math.clamp((v - a) / (b - a), 0, 1)
end

function MathUtil.RoundTo(value: number, step: number): number
	if step <= 0 then
		return value
	end
	return math.floor(value / step + 0.5) * step
end

return MathUtil
