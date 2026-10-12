--!strict
-- The single source of truth for mount speed. MountService uses it to drive mounts and
-- ProfileView uses it to show each pet's speed, so the UI and physics always agree.
--
--   speed (studs/s) = min(baseSpeed * tierMultiplier * (1 + upgradeLevel * UpgradeBonusPerLevel),
--                         MaxMountSpeed)

local MountStats = {}

export type SpeedConfig = {
	MaxMountSpeed: number,
	UpgradeBonusPerLevel: number,
}

function MountStats.computeSpeed(species: { baseSpeed: number, tierMultiplier: number }, upgradeLevel: number, config: SpeedConfig): number
	local level = math.max(0, math.floor(upgradeLevel))
	local speed = species.baseSpeed * species.tierMultiplier * (1 + level * config.UpgradeBonusPerLevel)
	return math.clamp(speed, 0, config.MaxMountSpeed)
end

function MountStats.canFly(species: { abilities: { string } }): boolean
	return table.find(species.abilities, "Flight") ~= nil
end

function MountStats.canDoubleJump(species: { abilities: { string } }): boolean
	return table.find(species.abilities, "DoubleJump") ~= nil
end

return MountStats
