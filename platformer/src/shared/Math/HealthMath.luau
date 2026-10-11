--!strict
-- Converts Humanoid health into a heart count.
--   perHeart        = maxHealth / heartCount
--   remainingHearts = clamp(ceil(health / perHeart), 0, heartCount)
-- A tiny epsilon keeps exact boundaries (e.g. 66.666...) on the lower count
-- despite floating-point rounding.

local HealthMath = {}

local BOUNDARY_EPSILON = 1e-6

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

function HealthMath.HeartsFromHealth(health: number, maxHealth: number, heartCount: number): number
	if type(heartCount) ~= "number" or not isFinite(heartCount) or heartCount < 1 then
		return 0
	end
	heartCount = math.floor(heartCount)
	if type(health) ~= "number" or health ~= health or health <= 0 then
		return 0
	end
	if type(maxHealth) ~= "number" or not isFinite(maxHealth) or maxHealth <= 0 then
		-- No usable maximum: any positive health shows as full.
		return heartCount
	end
	local perHeart = maxHealth / heartCount
	local hearts = math.ceil(math.min(health, maxHealth) / perHeart - BOUNDARY_EPSILON)
	return math.clamp(hearts, 0, heartCount)
end

return HealthMath
