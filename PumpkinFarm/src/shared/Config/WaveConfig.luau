--!strict
--[[
	WaveConfig
	Path: ReplicatedStorage.Shared.Config.WaveConfig

	Wave composition and pacing. WaveService turns these numbers (plus the multipliers
	from DifficultyService) into a deterministic spawn plan per wave.

	Archetype fields:
		UnlockWave      first wave the archetype may appear
		Weight          base weight for a non-grunt slot
		WeightPerWave   weight added per wave after unlock
		MaxShare        cap on the archetype's share of the wave (0..1)
		MaxPerWave      optional absolute cap
		Special         counts as a "specialized" enemy (affected by Continue special chance)
		Backline        spawns after the frontline lead (see FrontlineLead)
		Cost            threat points (a grunt costs GruntCost); see ThreatBudget

	Dependencies: Shared.Utilities.TableUtil
]]

local TableUtil = require(script.Parent.Parent.Utilities.TableUtil)

export type ArchetypeRule = {
	UnlockWave: number,
	Weight: number,
	WeightPerWave: number,
	MaxShare: number,
	MaxPerWave: number?,
	Special: boolean,
	Cost: number,
	Backline: boolean?,
}

local WaveConfig = {
	EnemyCount = {
		Base = 6,
		PerWave = 2.5,
		Growth = 1.035,
		Max = 140,
	},
	-- Fraction of a wave filled with non-grunt archetypes at wave N:
	-- min(SpecialShareMax, SpecialShareBase + SpecialSharePerWave * (N - 1)).
	SpecialShareBase = 0.1,
	SpecialSharePerWave = 0.025,
	SpecialShareMax = 0.55,

	-- Hard cap of enemies alive at once per match; the spawner waits below this.
	MaxAliveEnemies = 45,
	SpawnInterval = { Base = 1.6, PerWave = -0.05, Min = 0.35 },
	-- Enemies spawned per spawn tick: Base + floor((wave - 1) / PerWaves), capped at Max.
	BurstSize = { Base = 1, PerWaves = 5, Max = 4 },

	-- Fraction of the wave that spawns before any Backline archetype is released.
	FrontlineLead = 0.3,

	BossEvery = 10,
	BossEnemyId = "CursedHarvester",
	-- Boss waves keep this fraction of the normal enemy count as escort.
	BossEscortMultiplier = 0.5,

	-- Flying enemies spawn this far above the ground at the spawn point.
	AirSpawnHeight = 30,

	GruntEnemyId = "ZombieFarmer",

	-- Threat budget: every wave gets budget = slots * perSlot, where
	-- perSlot = min(Max, Base + PerWave * (wave - 1)) + PerContinue * ContinueLevel.
	-- Specialists are only picked while the budget can still pay for them AND a grunt
	-- for every remaining slot, so expensive mixes cannot appear early. The boss is
	-- outside the budget.
	GruntCost = 1,
	ThreatBudget = {
		Base = 1.25,
		PerWave = 0.06,
		Max = 2.6,
		PerContinue = 0.2,
	},

	Archetypes = {
		ZombieMole = { UnlockWave = 3, Weight = 12, WeightPerWave = 2, MaxShare = 0.25, Special = true, Cost = 2 },
		PlagueCrow = { UnlockWave = 4, Weight = 12, WeightPerWave = 1.5, MaxShare = 0.25, Special = true, Cost = 1.5 },
		BlightedScarecrow = { UnlockWave = 6, Weight = 10, WeightPerWave = 1.5, MaxShare = 0.2, Special = true, Cost = 2.5 },
		Witch = {
			UnlockWave = 8,
			Weight = 6,
			WeightPerWave = 0.8,
			MaxShare = 0.1,
			MaxPerWave = 4,
			Special = true,
			Backline = true,
			Cost = 4,
		},
	} :: { [string]: ArchetypeRule },
}

return TableUtil.DeepFreeze(WaveConfig)
