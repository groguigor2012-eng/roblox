--!strict
-- Rare taming items. Which pet needs which item lives in PetConfig.requiredItem;
-- where and how often items appear in the world lives in `spawn` below.
--
-- spawn.zones          zone ids (ZoneConfig) the pickup may appear in
-- spawn.maxActive      cap on simultaneous pickups of this item across the server
-- spawn.interval       seconds between spawn attempts while below the cap
-- spawn.despawnSeconds lifetime of an uncollected pickup
-- spawn.hidden         hidden pickups are small, dim and never shown on the compass

export type ItemSpawn = {
	zones: { string },
	maxActive: number,
	interval: number,
	despawnSeconds: number,
	hidden: boolean,
}

export type ItemDefinition = {
	displayName: string,
	rarity: string,
	description: string,
	shape: "Leaf" | "Nut" | "Pearl" | "Feather" | "Crystal" | "Core" | "Apple" | "Star",
	color: Color3,
	coinReward: number,
	spawn: ItemSpawn,
}

local ItemConfig = {}

ItemConfig.Items = {
	LuckyClover = {
		displayName = "Lucky Clover",
		rarity = "Common",
		description = "A four-leaf clover. Meadow Bunnies can't resist it.",
		shape = "Leaf",
		color = Color3.fromRGB(80, 210, 90),
		coinReward = 5,
		spawn = { zones = { "Meadow" }, maxActive = 6, interval = 15, despawnSeconds = 300, hidden = false },
	},
	GoldenAcorn = {
		displayName = "Golden Acorn",
		rarity = "Common",
		description = "Dropped by the oldest trees of the Whispering Forest.",
		shape = "Nut",
		color = Color3.fromRGB(230, 180, 60),
		coinReward = 5,
		spawn = { zones = { "Forest", "Meadow" }, maxActive = 6, interval = 15, despawnSeconds = 300, hidden = false },
	},
	MoonPearl = {
		displayName = "Moon Pearl",
		rarity = "Uncommon",
		description = "Forms only where moonlight touches still water.",
		shape = "Pearl",
		color = Color3.fromRGB(220, 230, 255),
		coinReward = 10,
		spawn = { zones = { "Lake", "Meadow" }, maxActive = 4, interval = 25, despawnSeconds = 300, hidden = false },
	},
	PhoenixFeather = {
		displayName = "Phoenix Feather",
		rarity = "Rare",
		description = "Still warm. Found where the canyon sun burns hottest.",
		shape = "Feather",
		color = Color3.fromRGB(255, 120, 40),
		coinReward = 20,
		spawn = { zones = { "Canyon" }, maxActive = 3, interval = 35, despawnSeconds = 240, hidden = true },
	},
	VoidCrystal = {
		displayName = "Void Crystal",
		rarity = "Epic",
		description = "A shard of pure darkness hidden in the deep forest.",
		shape = "Crystal",
		color = Color3.fromRGB(120, 60, 220),
		coinReward = 35,
		spawn = { zones = { "Forest", "Canyon" }, maxActive = 2, interval = 50, despawnSeconds = 240, hidden = true },
	},
	StormCore = {
		displayName = "Storm Core",
		rarity = "Legendary",
		description = "Crackles with captured lightning. Rests on the highest peaks.",
		shape = "Core",
		color = Color3.fromRGB(100, 170, 255),
		coinReward = 60,
		spawn = { zones = { "Peaks" }, maxActive = 2, interval = 70, despawnSeconds = 240, hidden = true },
	},
	GoldenApple = {
		displayName = "Golden Apple",
		rarity = "Mythical",
		description = "Said to grow on a single tree that moves every night.",
		shape = "Apple",
		color = Color3.fromRGB(255, 210, 40),
		coinReward = 120,
		spawn = { zones = { "Peaks", "Lake" }, maxActive = 1, interval = 120, despawnSeconds = 180, hidden = true },
	},
	StarShard = {
		displayName = "Star Shard",
		rarity = "Secret",
		description = "A fallen piece of the night sky.",
		shape = "Star",
		color = Color3.fromRGB(60, 255, 230),
		coinReward = 250,
		spawn = { zones = { "Peaks" }, maxActive = 1, interval = 240, despawnSeconds = 150, hidden = true },
	},
} :: { [string]: ItemDefinition }

function ItemConfig.get(itemId: string): ItemDefinition?
	return ItemConfig.Items[itemId]
end

return ItemConfig
