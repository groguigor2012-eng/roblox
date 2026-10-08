--!strict
--[[
	EnemyConfig
	Path: ReplicatedStorage.Shared.Config.EnemyConfig

	Base stats and behaviour tuning for every enemy archetype. Values are wave-1 values;
	DifficultyService scales Health/Speed/Damage per wave, player count and Continue level.

	Common fields:
		Class           AI module in ServerScriptService.Server.AI that drives the enemy
		MovementType    "Ground" | "Air" | "Underground" (used by crop Vulnerability)
		BaseHealth, BaseSpeed, Damage, AttackCooldown, AttackRange
		DetectionRange  distance at which a player pulls aggro
		CropDamage      damage per bite against crops
		StructureDamage damage per hit against barricades / sentries / the Great Pumpkin
		TargetPriority  weights per target kind used by TargetSelector
		CoinReward      Match Coins for the killer at wave 1 (RewardService scales it)
		Scaling         EnemyDifficultyModifier: how strongly wave growth applies (1 = fully)
		UpdateInterval  AI think rate in seconds (AIScheduler)
		StateUpdateIntervals  optional per-state think rates for state-machine AI
		Agent           pathfinding agent size
		Visual          ModelFactory.CreateEnemy parameters
		IsBoss, KnockbackResistance (0..1)

	Dependencies: Shared.Utilities.TableUtil
]]

local TableUtil = require(script.Parent.Parent.Utilities.TableUtil)

export type EnemyDefinition = { [string]: any }

local Enemies: { [string]: EnemyDefinition } = {
	ZombieFarmer = {
		Id = "ZombieFarmer",
		DisplayName = "Zombie Farmer",
		Class = "ZombieFarmer",
		Role = "Grunt",
		MovementType = "Ground",
		BaseHealth = 90,
		BaseSpeed = 10,
		Damage = 12,
		AttackCooldown = 1.3,
		AttackRange = 5,
		DetectionRange = 20,
		LeashRange = 34,
		CropDamage = 15,
		StructureDamage = 22,
		TargetPriority = { Crop = 3, Core = 1, Player = 2.5, Sentry = 1.2, Barricade = 0.6 },
		CoinReward = 10,
		Scaling = { Health = 1, Speed = 1 },
		UpdateInterval = 0.2,
		Agent = { Radius = 2, Height = 5 },
		KnockbackResistance = 0,
		Visual = {
			Kind = "Zombie",
			Scale = 1,
			SkinColor = Color3.fromRGB(122, 190, 96),
			ShirtColor = Color3.fromRGB(90, 120, 200),
			PantsColor = Color3.fromRGB(120, 86, 50),
			HatColor = Color3.fromRGB(230, 200, 110),
		},
	},
	ZombieFarmerMini = {
		Id = "ZombieFarmerMini",
		DisplayName = "Zombie Sprout",
		Class = "ZombieFarmer",
		Role = "Minion",
		MovementType = "Ground",
		BaseHealth = 40,
		BaseSpeed = 12,
		Damage = 6,
		AttackCooldown = 1.1,
		AttackRange = 4,
		DetectionRange = 18,
		LeashRange = 30,
		CropDamage = 8,
		StructureDamage = 10,
		TargetPriority = { Crop = 2, Core = 1, Player = 3, Sentry = 1 },
		CoinReward = 3,
		Scaling = { Health = 0.8, Speed = 1 },
		UpdateInterval = 0.25,
		Agent = { Radius = 1.5, Height = 4 },
		KnockbackResistance = 0,
		Visual = {
			Kind = "Zombie",
			Scale = 0.7,
			SkinColor = Color3.fromRGB(150, 210, 110),
			ShirtColor = Color3.fromRGB(170, 90, 200),
			PantsColor = Color3.fromRGB(90, 70, 50),
			HatColor = Color3.fromRGB(110, 200, 90),
		},
	},
	ZombieMole = {
		Id = "ZombieMole",
		DisplayName = "Zombie Mole",
		Class = "ZombieMole",
		Role = "Breacher",
		MovementType = "Underground",
		BaseHealth = 110,
		BaseSpeed = 9,
		UndergroundSpeed = 15,
		DigDepth = 5,
		EnterDuration = 1.2,
		ResurfaceDuration = 1,
		Damage = 10,
		AttackCooldown = 1,
		AttackRange = 6,
		DetectionRange = 12,
		LeashRange = 22,
		CropDamage = 22,
		StructureDamage = 10,
		-- Damage taken while underground (AoE magic reaches it, melee and sentries do not).
		UndergroundDamageMultiplier = 0.5,
		-- The Interrupted state (a player hit it on the surface) ends when no player hit
		-- it for this long.
		CombatTimeout = 6,
		-- Detour tunnels tried when the planned exit is blocked before surfacing anyway.
		SurfaceSearchAttempts = 3,
		-- Think rate per state (seconds); unlisted states use UpdateInterval.
		StateUpdateIntervals = {
			Idle = 0.3,
			SelectingTarget = 0.2,
			EnteringUnderground = 0.25,
			UndergroundTraversal = 0.1,
			SearchingSurfaceRoute = 0.2,
			Resurfacing = 0.25,
			AttackingCrop = 0.15,
			Interrupted = 0.15,
			Retargeting = 0.2,
			Dying = 1,
		},
		-- Max distance for walking (instead of digging) to the next crop.
		WalkRetargetDistance = 14,
		GridCellSize = 4,
		MaxRouteExpansions = 6000,
		TargetPriority = { Crop = 4, Core = 1 },
		CoinReward = 18,
		Scaling = { Health = 1, Speed = 0.8 },
		UpdateInterval = 0.15,
		Agent = { Radius = 2, Height = 4 },
		KnockbackResistance = 0.2,
		Visual = {
			Kind = "Mole",
			Scale = 1,
			SkinColor = Color3.fromRGB(110, 80, 70),
			ShirtColor = Color3.fromRGB(140, 200, 100),
			PantsColor = Color3.fromRGB(70, 50, 40),
			HatColor = Color3.fromRGB(255, 180, 60),
		},
	},
	BlightedScarecrow = {
		Id = "BlightedScarecrow",
		DisplayName = "Blighted Scarecrow",
		Class = "BlightedScarecrow",
		Role = "Leaper",
		MovementType = "Ground",
		BaseHealth = 140,
		BaseSpeed = 15,
		Damage = 18,
		AttackCooldown = 1.4,
		AttackRange = 5,
		DetectionRange = 80,
		LeashRange = 120,
		CropDamage = 10,
		StructureDamage = 30,
		LeapCooldown = 6,
		LeapMinDistance = 10,
		LeapMaxDistance = 38,
		LeapWindup = 0.45,
		LeapDuration = 0.9,
		-- A barricade this close on the way to the target triggers a vault.
		LeapTriggerRange = 16,
		LandingRadius = 9,
		LandingDamage = 20,
		LandingStructureDamage = 120,
		StunDuration = 2,
		TargetPriority = { Player = 5, Crop = 1, Core = 0.5 },
		CoinReward = 22,
		Scaling = { Health = 1, Speed = 0.6 },
		UpdateInterval = 0.12,
		Agent = { Radius = 2, Height = 6 },
		KnockbackResistance = 0.3,
		Visual = {
			Kind = "Scarecrow",
			Scale = 1.1,
			SkinColor = Color3.fromRGB(210, 170, 90),
			ShirtColor = Color3.fromRGB(150, 50, 60),
			PantsColor = Color3.fromRGB(80, 90, 130),
			HatColor = Color3.fromRGB(60, 40, 30),
		},
	},
	PlagueCrow = {
		Id = "PlagueCrow",
		DisplayName = "Plague Crow",
		Class = "PlagueCrow",
		Role = "AirThief",
		MovementType = "Air",
		BaseHealth = 45,
		BaseSpeed = 22,
		Damage = 6,
		AttackCooldown = 1,
		AttackRange = 4,
		DetectionRange = 0,
		LeashRange = 0,
		CropDamage = 10,
		StructureDamage = 8,
		CruiseAltitude = 26,
		DiveSpeedMultiplier = 0.8,
		StealDuration = 1.2,
		StealsBeforeEscape = 1,
		TargetPriority = { Crop = 5, Core = 1 },
		CoinReward = 12,
		Scaling = { Health = 0.9, Speed = 0.5 },
		UpdateInterval = 0.1,
		Agent = { Radius = 2, Height = 2 },
		KnockbackResistance = 0,
		Visual = {
			Kind = "Crow",
			Scale = 1,
			SkinColor = Color3.fromRGB(40, 30, 60),
			ShirtColor = Color3.fromRGB(120, 255, 90),
			PantsColor = Color3.fromRGB(255, 200, 40),
			HatColor = Color3.fromRGB(40, 30, 60),
		},
	},
	Witch = {
		Id = "Witch",
		DisplayName = "Bog Witch",
		Class = "Witch",
		Role = "Spawner",
		MovementType = "Ground",
		BaseHealth = 160,
		BaseSpeed = 9,
		Damage = 0,
		AttackCooldown = 4.5,
		AttackRange = 46,
		DetectionRange = 70,
		LeashRange = 120,
		PreferredRange = { 24, 44 },
		PotionFlightTime = 1.1,
		PotionSplashRadius = 9,
		PotionDamage = 8,
		PotionEffect = "Slowed",
		SummonCooldown = 12,
		SummonCount = 2,
		MaxMinions = 4,
		MinionId = "ZombieFarmerMini",
		-- Other witches closer than this push each other apart (prevents clumping).
		SeparationRadius = 10,
		-- Stay at least this far behind the closest allied ground enemy (to the player).
		FrontlineBuffer = 6,
		CropDamage = 0,
		StructureDamage = 0,
		TargetPriority = { Player = 1 },
		CoinReward = 35,
		Scaling = { Health = 1, Speed = 0.5 },
		UpdateInterval = 0.25,
		Agent = { Radius = 2, Height = 6 },
		KnockbackResistance = 0.1,
		Visual = {
			Kind = "Witch",
			Scale = 1.05,
			SkinColor = Color3.fromRGB(130, 200, 120),
			ShirtColor = Color3.fromRGB(70, 30, 110),
			PantsColor = Color3.fromRGB(40, 20, 60),
			HatColor = Color3.fromRGB(30, 15, 45),
		},
	},
	CursedHarvester = {
		Id = "CursedHarvester",
		DisplayName = "The Cursed Harvester",
		Class = "CursedHarvester",
		Role = "Boss",
		MovementType = "Ground",
		IsBoss = true,
		BaseHealth = 6000,
		BaseSpeed = 11,
		Damage = 45,
		AttackCooldown = 2.2,
		AttackRange = 12,
		DetectionRange = 26,
		LeashRange = 40,
		CropDamage = 200,
		StructureDamage = 400,
		SweepRadius = 16,
		SweepCooldown = 5,
		CrushRadius = 11,
		-- Barricades and sentries inside this radius are hunted before crops.
		DefenseSeekRadius = 70,
		-- Aura: radius and the buffs it grants nearby enemies (configurable per boss).
		AuraRadius = 35,
		AuraSpeedBuff = 1.35,
		AuraAttackSpeedBuff = 1.2,
		AuraPulseInterval = 0.5,
		EnrageThreshold = 0.3,
		EnrageSpeedMultiplier = 1.2,
		IntroDuration = 3,
		TargetPriority = { Barricade = 4, Sentry = 4, Crop = 3, Core = 2, Player = 1.5 },
		CoinReward = 0,
		Scaling = { Health = 0.6, Speed = 0.4 },
		UpdateInterval = 0.1,
		Agent = { Radius = 5, Height = 16 },
		KnockbackResistance = 1,
		Visual = {
			Kind = "Harvester",
			Scale = 3,
			SkinColor = Color3.fromRGB(60, 50, 70),
			ShirtColor = Color3.fromRGB(110, 20, 40),
			PantsColor = Color3.fromRGB(40, 30, 40),
			HatColor = Color3.fromRGB(255, 120, 20),
		},
	},
}

local EnemyConfig = {
	Enemies = Enemies,
	-- Enemies that fall below this Y offset from the arena floor are removed (void safety).
	KillPlaneDepth = 60,
	-- Seconds a corpse stays before its model is destroyed.
	CorpseLifetime = 1.5,
	-- Maximum pathfinding computations running at once across the server.
	MaxConcurrentPathRequests = 6,
	-- Re-path when the goal moved more than this many studs.
	RepathDistance = 8,
	-- Minimum seconds between re-paths for one enemy.
	RepathInterval = 1.5,
	-- An agent that moves less than StuckDistance during StuckTime is considered stuck.
	StuckDistance = 1.5,
	StuckTime = 1.5,
}

function EnemyConfig.Get(enemyId: string): EnemyDefinition?
	return Enemies[enemyId]
end

return TableUtil.DeepFreeze(EnemyConfig)
