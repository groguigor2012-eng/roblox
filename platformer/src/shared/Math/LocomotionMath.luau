--!strict
-- Pure maths for the locomotion animation layer and footstep/collect audio
-- (unit-tested headlessly).

local LocomotionMath = {}

local function clamp01(t: number): number
	if t ~= t then
		return 0
	end
	return math.clamp(t, 0, 1)
end

-- Moving/stationary with hysteresis: start above startSpeed, stop below
-- stopSpeed, so speeds hovering near one threshold never flicker.
function LocomotionMath.IsMoving(speed: number, wasMoving: boolean, startSpeed: number, stopSpeed: number): boolean
	if wasMoving then
		return speed >= stopSpeed
	end
	return speed > startSpeed
end

-- Run share of the walk/run blend: 0 below blendStart, 1 above blendEnd,
-- linear in between. Returns (walkWeight, runWeight), always summing to 1.
function LocomotionMath.WalkRunWeights(speed: number, blendStart: number, blendEnd: number): (number, number)
	local run
	if blendEnd <= blendStart then
		run = if speed >= blendEnd then 1 else 0
	else
		run = clamp01((speed - blendStart) / (blendEnd - blendStart))
	end
	return 1 - run, run
end

-- Animation timewarp that keeps feet in step with the ground:
-- speed / (referenceSpeed * sizeScale), clamped to [minSpeed, maxSpeed].
function LocomotionMath.PlaybackSpeed(
	speed: number,
	referenceSpeed: number,
	sizeScale: number,
	minSpeed: number,
	maxSpeed: number
): number
	local reference = referenceSpeed * math.max(sizeScale, 0.05)
	if reference <= 0 then
		return 1
	end
	return math.clamp(speed / reference, minSpeed, maxSpeed)
end

-- Linear blend between a walk value and a run value by run weight.
function LocomotionMath.Blend(walkValue: number, runValue: number, runWeight: number): number
	return walkValue + (runValue - walkValue) * clamp01(runWeight)
end

-- Surface name for a floor material: the mapped surface if it has sounds,
-- otherwise "Default".
function LocomotionMath.SurfaceFor(
	materialName: string,
	materialSurfaces: { [string]: string },
	surfaces: { [string]: { string } }
): string
	local surface = materialSurfaces[materialName]
	if surface and surfaces[surface] and #surfaces[surface] > 0 then
		return surface
	end
	return "Default"
end

-- Picks an index in 1..count, avoiding `last` when there is a choice.
-- `roll` is a random number in [0, 1).
function LocomotionMath.PickVariant(count: number, last: number?, roll: number): number
	if count <= 1 then
		return 1
	end
	if last and last >= 1 and last <= count then
		local index = 1 + math.floor(math.clamp(roll, 0, 0.999999) * (count - 1))
		return if index >= last then index + 1 else index
	end
	return 1 + math.floor(math.clamp(roll, 0, 0.999999) * count)
end

-- Playback-speed multiplier for the n-th pickup in a streak (n = 0 first).
function LocomotionMath.ChainSpeed(streak: number, semitonesPerStep: number, maxSteps: number): number
	local steps = math.clamp(math.floor(streak), 0, math.max(maxSteps, 0))
	return 2 ^ (steps * semitonesPerStep / 12)
end

return LocomotionMath
