--!strict
-- Every collectible species. Adding a pet = add an entry here, reference it from an
-- egg pool in EggConfig, and (optionally) drop a model named after the species id into
-- ServerStorage.PetModels / ServerStorage.MountModels. Without a model, a labelled
-- placeholder rig is generated from `look`.
--
-- abilities:
--   "Jump"        ground jump while mounted
--   "DoubleJump"  one extra jump in the air
--   "Flight"      take off, climb, descend (requires mountType = "Flying")

export type PetLook = {
	bodyColor: Color3,
	accentColor: Color3,
	scale: number,
	-- Shape hints for the placeholder rig.
	ears: boolean?,
	horn: boolean?,
	shell: boolean?,
	longTail: boolean?,
}

export type PetSpecies = {
	displayName: string,
	rarity: string,
	requiredItem: string,
	mountType: "Land" | "Flying",
	baseSpeed: number, -- studs per second before multipliers
	tierMultiplier: number,
	abilities: { string },
	description: string,
	look: PetLook,
}

local PetConfig = {}

PetConfig.Species = {
	MeadowBunny = {
		displayName = "Meadow Bunny",
		rarity = "Common",
		requiredItem = "LuckyClover",
		mountType = "Land",
		baseSpeed = 30,
		tierMultiplier = 1.0,
		abilities = { "Jump" },
		description = "A cheerful hopper found in every sunny field.",
		look = { bodyColor = Color3.fromRGB(236, 226, 210), accentColor = Color3.fromRGB(255, 170, 190), scale = 0.9, ears = true },
	},
	PebbleBoar = {
		displayName = "Pebble Boar",
		rarity = "Common",
		requiredItem = "GoldenAcorn",
		mountType = "Land",
		baseSpeed = 32,
		tierMultiplier = 1.0,
		abilities = { "Jump" },
		description = "Stubborn, sturdy and surprisingly fast downhill.",
		look = { bodyColor = Color3.fromRGB(128, 104, 88), accentColor = Color3.fromRGB(230, 222, 200), scale = 1.0, horn = true },
	},
	MoonTurtle = {
		displayName = "Moon Turtle",
		rarity = "Uncommon",
		requiredItem = "MoonPearl",
		mountType = "Land",
		baseSpeed = 28,
		tierMultiplier = 1.15,
		abilities = { "Jump" },
		description = "Glows faintly under the night sky.",
		look = { bodyColor = Color3.fromRGB(110, 170, 150), accentColor = Color3.fromRGB(200, 220, 255), scale = 1.1, shell = true },
	},
	EmberWolf = {
		displayName = "Ember Wolf",
		rarity = "Rare",
		requiredItem = "PhoenixFeather",
		mountType = "Land",
		baseSpeed = 40,
		tierMultiplier = 1.3,
		abilities = { "Jump", "DoubleJump" },
		description = "Leaves glowing pawprints wherever it runs.",
		look = { bodyColor = Color3.fromRGB(196, 72, 40), accentColor = Color3.fromRGB(255, 196, 64), scale = 1.15, ears = true, longTail = true },
	},
	ShadowFox = {
		displayName = "Shadow Fox",
		rarity = "Epic",
		requiredItem = "VoidCrystal",
		mountType = "Land",
		baseSpeed = 46,
		tierMultiplier = 1.5,
		abilities = { "Jump", "DoubleJump" },
		description = "Slips between shadows faster than the eye can follow.",
		look = { bodyColor = Color3.fromRGB(44, 40, 64), accentColor = Color3.fromRGB(150, 90, 255), scale = 1.1, ears = true, longTail = true },
	},
	StormGriffin = {
		displayName = "Storm Griffin",
		rarity = "Legendary",
		requiredItem = "StormCore",
		mountType = "Flying",
		baseSpeed = 48,
		tierMultiplier = 1.8,
		abilities = { "Jump", "Flight" },
		description = "Rides the thunderheads above the high peaks.",
		look = { bodyColor = Color3.fromRGB(214, 190, 120), accentColor = Color3.fromRGB(110, 150, 230), scale = 1.35, ears = true },
	},
	SkyPegasus = {
		displayName = "Sky Pegasus",
		rarity = "Mythical",
		requiredItem = "GoldenApple",
		mountType = "Flying",
		baseSpeed = 52,
		tierMultiplier = 2.1,
		abilities = { "Jump", "Flight" },
		description = "A winged legend said to carry riders above the clouds.",
		look = { bodyColor = Color3.fromRGB(245, 245, 255), accentColor = Color3.fromRGB(150, 210, 255), scale = 1.4, horn = true, longTail = true },
	},
	CelestialDragon = {
		displayName = "Celestial Dragon",
		rarity = "Secret",
		requiredItem = "StarShard",
		mountType = "Flying",
		baseSpeed = 55,
		tierMultiplier = 2.5,
		abilities = { "Jump", "DoubleJump", "Flight" },
		description = "Nobody is sure it exists. Somebody hatched one anyway.",
		look = { bodyColor = Color3.fromRGB(30, 36, 90), accentColor = Color3.fromRGB(60, 255, 230), scale = 1.6, horn = true, longTail = true },
	},
} :: { [string]: PetSpecies }

function PetConfig.get(speciesId: string): PetSpecies?
	return PetConfig.Species[speciesId]
end

function PetConfig.hasAbility(speciesId: string, ability: string): boolean
	local species = PetConfig.Species[speciesId]
	if not species then
		return false
	end
	return table.find(species.abilities, ability) ~= nil
end

return PetConfig
