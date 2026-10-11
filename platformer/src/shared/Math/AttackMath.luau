--!strict
-- Pure maths for the right-click attack (unit-tested headlessly).

local AttackMath = {}

export type FallbackPose = {
	WindupTime: number,
	StrikeTime: number,
	HoldTime: number,
	RecoveryTime: number,
	WindupShoulderPitch: number,
	StrikeShoulderPitch: number,
	WindupElbowBend: number,
	WindupWaistTwist: number,
	StrikeWaistTwist: number,
}

local MIN_PHASE = 1e-3

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Smooth start and end: -(cos(pi t) - 1) / 2.
local function sineInOut(t: number): number
	return -(math.cos(math.pi * math.clamp(t, 0, 1)) - 1) / 2
end

-- Fast start, gentle stop: 1 - (1 - t)^2.
local function quadOut(t: number): number
	local clamped = math.clamp(t, 0, 1)
	return 1 - (1 - clamped) ^ 2
end

function AttackMath.TotalTime(pose: FallbackPose): number
	return pose.WindupTime + pose.StrikeTime + pose.HoldTime + pose.RecoveryTime
end

-- Joint angles (degrees) of the procedural punch `elapsed` seconds in:
--   wind-up   0 -> wind-up angles          (sine in-out)
--   strike    wind-up -> strike angles     (quad out: snaps forward)
--   hold      strike angles
--   recovery  strike -> 0                  (sine in-out)
-- Returns (shoulderPitch, elbowBend, waistTwist, finished). Every phase
-- starts where the previous one ended, so the motion has no jumps, and the
-- pose is exactly neutral once finished.
function AttackMath.FallbackPose(pose: FallbackPose, elapsed: number): (number, number, number, boolean)
	local windup = math.max(pose.WindupTime, MIN_PHASE)
	local strike = math.max(pose.StrikeTime, MIN_PHASE)
	local hold = math.max(pose.HoldTime, 0)
	local recovery = math.max(pose.RecoveryTime, MIN_PHASE)

	if elapsed < 0 then
		return 0, 0, 0, false
	end
	if elapsed < windup then
		local t = sineInOut(elapsed / windup)
		return lerp(0, pose.WindupShoulderPitch, t), lerp(0, pose.WindupElbowBend, t), lerp(0, pose.WindupWaistTwist, t), false
	end
	elapsed -= windup
	if elapsed < strike then
		local t = quadOut(elapsed / strike)
		return lerp(pose.WindupShoulderPitch, pose.StrikeShoulderPitch, t),
			lerp(pose.WindupElbowBend, 0, t),
			lerp(pose.WindupWaistTwist, pose.StrikeWaistTwist, t),
			false
	end
	elapsed -= strike
	if elapsed < hold then
		return pose.StrikeShoulderPitch, 0, pose.StrikeWaistTwist, false
	end
	elapsed -= hold
	if elapsed < recovery then
		local t = sineInOut(elapsed / recovery)
		return lerp(pose.StrikeShoulderPitch, 0, t), 0, lerp(pose.StrikeWaistTwist, 0, t), false
	end
	return 0, 0, 0, true
end

-- A right-button press counts as a click (not a camera drag) when it was
-- short and the mouse barely moved.
function AttackMath.IsClick(holdTime: number, dragPixels: number, maxHoldTime: number, maxDragPixels: number): boolean
	return holdTime >= 0 and holdTime <= maxHoldTime and dragPixels <= maxDragPixels
end

return AttackMath
