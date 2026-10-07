--!strict
--[[
	SeedConfig
	Path: ReplicatedStorage.Shared.Config.SeedConfig

	Randomized Seed Shop rules. The server (SeedShopService) rolls a fresh stock every
	Intermission and every ContinuePreparation from these entries with a seeded Random;
	clients only ever display the result. Seed ids are crop ids (see CropConfig).

	Fields per seed:
		Weight          relative chance to appear in a rotating slot
		MinWave         earliest wave the seed may appear (0 = from the first intermission)
		Quantity        { min, max } stock for a solo match (scaled by player count)
		PriceVariance   { min, max } multiplier applied to CropConfig SeedPrice
		PerPlayerLimit  optional max purchases per player per restock
		AlwaysStocked   occupies a guaranteed slot so new players can always farm

	Dependencies: Shared.Utilities.TableUtil
]]

local TableUtil = require(script.Parent.Parent.Utilities.TableUtil)

export type SeedRule = {
	Weight: number,
	MinWave: number,
	Quantity: { number },
	PriceVariance: { number },
	PerPlayerLimit: number?,
	AlwaysStocked: boolean?,
}

local SeedConfig = {
	-- Total stock entries per restock (always-stocked seeds count toward this).
	SlotCount = 3,
	-- Final prices are rounded to this step so the UI shows tidy numbers.
	PriceRoundTo = 5,
	-- Each extra player adds this fraction of the base quantity.
	QuantityPerExtraPlayer = 0.5,
	-- Each Continue level multiplies the weight of Rare/Epic seeds by (1 + boost * level).
	RarityBoostPerContinue = 0.35,
	BoostedRarities = { "Rare", "Epic" },

	Seeds = {
		NeonStarFruit = {
			Weight = 100,
			MinWave = 0,
			Quantity = { 6, 10 },
			PriceVariance = { 0.9, 1.1 },
			AlwaysStocked = true,
		},
		PhantomCorn = {
			Weight = 70,
			MinWave = 0,
			Quantity = { 3, 6 },
			PriceVariance = { 0.9, 1.15 },
		},
		GhostPepper = {
			Weight = 60,
			MinWave = 2,
			Quantity = { 3, 5 },
			PriceVariance = { 0.85, 1.15 },
		},
		VoidPumpkin = {
			Weight = 25,
			MinWave = 4,
			Quantity = { 1, 3 },
			PriceVariance = { 0.85, 1.2 },
			PerPlayerLimit = 2,
		},
		WraithMelon = {
			Weight = 10,
			MinWave = 9,
			Quantity = { 1, 2 },
			PriceVariance = { 0.9, 1.25 },
			PerPlayerLimit = 1,
		},
	} :: { [string]: SeedRule },
}

return TableUtil.DeepFreeze(SeedConfig)
