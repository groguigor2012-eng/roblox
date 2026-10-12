--!strict
-- Egg tiers and their reward pools.
--
-- pool: species id -> integer weight. The chance of a species from an egg of this tier
-- is exactly weight / sum(weights), and that is the "1 in N" shown on billboards and in
-- the hatch reveal (see Shared/Odds). Odds are always per egg of the given tier.
--
-- itemDropChance: chance that claiming this egg also drops the taming item of the
-- hatched pet next to the egg (the "world drop" system). 0 disables it.

export type EggTier = {
	displayName: string,
	color: Color3,
	coinReward: number,
	holdDuration: number, -- ProximityPrompt hold time in seconds
	itemDropChance: number,
	pool: { [string]: number },
}

local EggConfig = {}

EggConfig.Tiers = {
	Common = {
		displayName = "Common Egg",
		color = Color3.fromRGB(230, 225, 210),
		coinReward = 20,
		holdDuration = 0.5,
		itemDropChance = 0.35,
		pool = { MeadowBunny = 70, PebbleBoar = 28, MoonTurtle = 2 },
	},
	Uncommon = {
		displayName = "Uncommon Egg",
		color = Color3.fromRGB(120, 220, 140),
		coinReward = 35,
		holdDuration = 0.6,
		itemDropChance = 0.25,
		pool = { PebbleBoar = 50, MoonTurtle = 45, EmberWolf = 5 },
	},
	Rare = {
		displayName = "Rare Egg",
		color = Color3.fromRGB(90, 160, 255),
		coinReward = 60,
		holdDuration = 0.7,
		itemDropChance = 0.15,
		pool = { MoonTurtle = 60, EmberWolf = 38, ShadowFox = 2 },
	},
	Epic = {
		displayName = "Epic Egg",
		color = Color3.fromRGB(180, 100, 255),
		coinReward = 100,
		holdDuration = 0.8,
		itemDropChance = 0.1,
		pool = { EmberWolf = 70, ShadowFox = 29, StormGriffin = 1 },
	},
	Legendary = {
		displayName = "Legendary Egg",
		color = Color3.fromRGB(255, 190, 50),
		coinReward = 200,
		holdDuration = 1.0,
		itemDropChance = 0.05,
		pool = { ShadowFox = 8000, StormGriffin = 1990, SkyPegasus = 10 },
	},
	Mythical = {
		displayName = "Mythical Egg",
		color = Color3.fromRGB(255, 80, 140),
		coinReward = 400,
		holdDuration = 1.2,
		itemDropChance = 0.03,
		pool = { StormGriffin = 9000, SkyPegasus = 1000 },
	},
	Secret = {
		displayName = "Secret Egg",
		color = Color3.fromRGB(40, 40, 50),
		coinReward = 1000,
		holdDuration = 1.5,
		itemDropChance = 0,
		pool = { SkyPegasus = 99, CelestialDragon = 1 },
	},
} :: { [string]: EggTier }

-- Seconds an unclaimed egg stays in the world (zones may override).
EggConfig.DefaultDespawnSeconds = 300

function EggConfig.get(tier: string): EggTier?
	return EggConfig.Tiers[tier]
end

return EggConfig
