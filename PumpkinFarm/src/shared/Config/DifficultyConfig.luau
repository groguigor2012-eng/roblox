--!strict
--[[
	DifficultyConfig
	Path: ReplicatedStorage.Shared.Config.DifficultyConfig

	Every number that controls how hard the game gets. DifficultyService is the only
	consumer; no other module multiplies difficulty on its own.

	Wave curves: each stat grows by `Growth` per wave (the design's nominal 1.2x),
	raised to `Exponent` so stats that must not explode (speed) grow gently. After
	`SoftCapWave` the per-wave growth switches to `PostSoftCapGrowth`, and the final
	multiplier never exceeds `MaxMultiplier`:

		mult(w) = min(Max, Growth ^ (Exponent * (min(w, SoftCap) - 1)) * PostGrowth ^ max(0, w - SoftCap))

	Per-enemy EnemyConfig.Scaling (the EnemyDifficultyModifier) then interpolates how
	much of that growth an archetype receives: 1 + (mult - 1) * scaling.

	Continue mode: every Continue raises ContinueLevel by one. A stat's continue factor
	is 1 + (Multiplier ^ level - 1) * Weight, so the 1.5x multiplier hits health fully,
	but speed, damage and density only partially.

	Dependencies: Shared.Utilities.TableUtil
]]

local TableUtil = require(script.Parent.Parent.Utilities.TableUtil)

export type Curve = {
	Growth: number,
	Exponent: number,
	SoftCapWave: number,
	PostSoftCapGrowth: number,
	MaxMultiplier: number,
}

local DifficultyConfig = {
	Curves = {
		Health = { Growth = 1.2, Exponent = 1, SoftCapWave = 15, PostSoftCapGrowth = 1.05, MaxMultiplier = 40 },
		Speed = { Growth = 1.2, Exponent = 0.15, SoftCapWave = 25, PostSoftCapGrowth = 1, MaxMultiplier = 1.6 },
		Damage = { Growth = 1.2, Exponent = 0.35, SoftCapWave = 20, PostSoftCapGrowth = 1.01, MaxMultiplier = 4 },
	} :: { [string]: Curve },

	Players = {
		-- Enemy health bonus per player beyond the first.
		HealthPerExtraPlayer = 0.35,
		-- Enemy count bonus per player beyond the first.
		DensityPerExtraPlayer = 0.5,
	},

	Continue = {
		Multiplier = 1.5,
		MaxLevel = 10,
		Weights = {
			Health = 1,
			Speed = 0.3,
			Damage = 0.5,
			Density = 0.6,
			SpawnPressure = 0.5,
			BossHealth = 1,
		},
		-- Specialized archetype weights are multiplied by (1 + SpecialChancePerLevel * level).
		SpecialChancePerLevel = 0.25,
		-- Extra share of the wave that may be specialized per level (added to SpecialShare).
		SpecialSharePerLevel = 0.05,
	},

	Boss = {
		-- Each subsequent boss (wave 20, 30, ...) gains this much extra health.
		HealthPerBossIndex = 0.5,
	},
}

return TableUtil.DeepFreeze(DifficultyConfig)
