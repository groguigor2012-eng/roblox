--!strict
--[[
	CropConfig
	Path: ReplicatedStorage.Shared.Config.CropConfig

	Every crop that can be planted. Crop ids double as seed ids (SeedConfig adds shop
	rules on top). All values are read by the server for authoritative growth, damage
	and harvest calculations; the client only reads them for display.

	Fields:
		SeedPrice        base seed price in Candies (SeedShopService applies variance)
		GrowthDuration   seconds from planting to ripe
		Stages           visual growth stages; AtProgress is the 0..1 growth fraction
		YieldQuantity    units added to the Harvest Chest on harvest
		UnitValue        Candy value of one unit at extraction (before risk bonus)
		MaxHealth        damage the plant can take before it is destroyed
		Vulnerability    damage multiplier per attacker movement type
		Special          optional special property, interpreted by Server.Classes.Crop
		                 Thorns       { Damage }            damages enemies that bite it
		                 Decoy        { PriorityBonus }     enemies prefer it as a target
		                 Anchored     {}                    crows cannot steal it (they peck)
		                 Regenerate   { HealthPerSecond }   heals over time
		Visual           procedural model parameters (ModelFactory.CreateCrop)

	Dependencies: Shared.Utilities.TableUtil
]]

local TableUtil = require(script.Parent.Parent.Utilities.TableUtil)

export type CropStage = { Name: string, AtProgress: number, Scale: number }

export type CropDefinition = {
	Id: string,
	DisplayName: string,
	Description: string,
	Rarity: string,
	SeedPrice: number,
	GrowthDuration: number,
	Stages: { CropStage },
	YieldQuantity: number,
	UnitValue: number,
	MaxHealth: number,
	Vulnerability: { Ground: number, Air: number, Underground: number, Boss: number },
	Special: { Type: string, Damage: number?, PriorityBonus: number?, HealthPerSecond: number? }?,
	Visual: {
		Kind: string,
		Color: Color3,
		SecondaryColor: Color3,
		Glow: boolean,
		RipeSize: number,
	},
	Icon: string,
	SortOrder: number,
}

local DEFAULT_STAGES: { CropStage } = {
	{ Name = "Seedling", AtProgress = 0, Scale = 0.2 },
	{ Name = "Sprout", AtProgress = 0.25, Scale = 0.45 },
	{ Name = "Growing", AtProgress = 0.6, Scale = 0.75 },
	{ Name = "Ripe", AtProgress = 1, Scale = 1 },
}

local Crops: { [string]: CropDefinition } = {
	NeonStarFruit = {
		Id = "NeonStarFruit",
		DisplayName = "Neon Star-Fruit",
		Description = "A glowing alien fruit that ripens fast. Reliable, low risk.",
		Rarity = "Common",
		SeedPrice = 30,
		GrowthDuration = 40,
		Stages = DEFAULT_STAGES,
		YieldQuantity = 2,
		UnitValue = 40,
		MaxHealth = 120,
		Vulnerability = { Ground = 1, Air = 1, Underground = 1, Boss = 1 },
		Special = nil,
		Visual = {
			Kind = "Star",
			Color = Color3.fromRGB(255, 240, 80),
			SecondaryColor = Color3.fromRGB(80, 255, 200),
			Glow = true,
			RipeSize = 3.2,
		},
		Icon = "⭐",
		SortOrder = 1,
	},
	PhantomCorn = {
		Id = "PhantomCorn",
		DisplayName = "Phantom Corn",
		Description = "Translucent corn that zombies find irresistible. Plant it to draw attackers away.",
		Rarity = "Uncommon",
		SeedPrice = 55,
		GrowthDuration = 55,
		Stages = DEFAULT_STAGES,
		YieldQuantity = 4,
		UnitValue = 25,
		MaxHealth = 220,
		Vulnerability = { Ground = 1, Air = 1, Underground = 1, Boss = 1 },
		Special = { Type = "Decoy", PriorityBonus = 2.5 },
		Visual = {
			Kind = "Corn",
			Color = Color3.fromRGB(220, 235, 255),
			SecondaryColor = Color3.fromRGB(120, 200, 140),
			Glow = false,
			RipeSize = 4.5,
		},
		Icon = "🌽",
		SortOrder = 2,
	},
	GhostPepper = {
		Id = "GhostPepper",
		DisplayName = "Ghost Pepper",
		Description = "A haunted pepper that burns anything that bites it.",
		Rarity = "Uncommon",
		SeedPrice = 80,
		GrowthDuration = 70,
		Stages = DEFAULT_STAGES,
		YieldQuantity = 3,
		UnitValue = 50,
		MaxHealth = 160,
		Vulnerability = { Ground = 1, Air = 1.25, Underground = 1, Boss = 1 },
		Special = { Type = "Thorns", Damage = 12 },
		Visual = {
			Kind = "Pepper",
			Color = Color3.fromRGB(240, 240, 255),
			SecondaryColor = Color3.fromRGB(150, 220, 255),
			Glow = true,
			RipeSize = 3,
		},
		Icon = "🌶️",
		SortOrder = 3,
	},
	VoidPumpkin = {
		Id = "VoidPumpkin",
		DisplayName = "Void Pumpkin",
		Description = "A rare pumpkin from the space between stars. Far too heavy for crows to carry.",
		Rarity = "Rare",
		SeedPrice = 220,
		GrowthDuration = 120,
		Stages = DEFAULT_STAGES,
		YieldQuantity = 1,
		UnitValue = 600,
		MaxHealth = 450,
		Vulnerability = { Ground = 1, Air = 0.75, Underground = 1.25, Boss = 1 },
		Special = { Type = "Anchored" },
		Visual = {
			Kind = "Pumpkin",
			Color = Color3.fromRGB(70, 20, 120),
			SecondaryColor = Color3.fromRGB(190, 90, 255),
			Glow = true,
			RipeSize = 5.5,
		},
		Icon = "🎃",
		SortOrder = 4,
	},
	WraithMelon = {
		Id = "WraithMelon",
		DisplayName = "Wraith Melon",
		Description = "An epic melon that slowly mends its own wounds.",
		Rarity = "Epic",
		SeedPrice = 450,
		GrowthDuration = 160,
		Stages = DEFAULT_STAGES,
		YieldQuantity = 1,
		UnitValue = 1100,
		MaxHealth = 380,
		Vulnerability = { Ground = 1, Air = 1, Underground = 1, Boss = 1.25 },
		Special = { Type = "Regenerate", HealthPerSecond = 4 },
		Visual = {
			Kind = "Melon",
			Color = Color3.fromRGB(40, 160, 110),
			SecondaryColor = Color3.fromRGB(200, 255, 220),
			Glow = true,
			RipeSize = 5,
		},
		Icon = "🍈",
		SortOrder = 5,
	},
}

local CropConfig = {
	Crops = Crops,
	-- Growth/health simulation tick (CropService). Attributes replicate at this rate.
	TickInterval = 0.5,
	-- Max fraction of a crop's health restored when a match enters ContinuePreparation.
	ContinueHealFraction = 0.25,
}

function CropConfig.Get(cropId: string): CropDefinition?
	return Crops[cropId]
end

return TableUtil.DeepFreeze(CropConfig)
