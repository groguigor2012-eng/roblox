--!strict
--[[
	DefenseConfig
	Path: ReplicatedStorage.Shared.Config.DefenseConfig

	Everything bought with Match Coins: placed defenses (barricades, sentries) and
	carried items (accessories, utilities). DefenseService validates and charges;
	BarricadeService / SentryService run the placed structures.

	Placed defense fields:
		Kind            "Barricade" | "Sentry"
		Cost, MaxHealth, Size (footprint used for overlap checks)
		Upgrades        ordered list; each level multiplies the base stats
		Sentry only:    SentryType "Bolt" (single target) | "Pulse" (area),
		                Range, Damage, FireInterval, CanTargetAir, Effect
	Item fields:
		Kind            "Accessory" (permanent for the match, one each) | "Utility" (consumed)
		Stats           accessory stat bonuses: MaxHealth, WalkSpeed, CoinMultiplier
		Utility:        HealAmount | RepairFraction, Cooldown (per player)

	Dependencies: Shared.Utilities.TableUtil
]]

local TableUtil = require(script.Parent.Parent.Utilities.TableUtil)

local DefenseConfig = {
	Placement = {
		-- Defenses must sit in the ring between these radii around the farm centre.
		InnerRadius = 14,
		OuterRadius = 95,
		-- Max distance between the buyer's character and the placement point.
		MaxPlaceDistance = 45,
		-- Gap kept between a new footprint and existing objects.
		Clearance = 0.5,
		MaxDefensesPerMatch = 30,
		MaxSentriesPerMatch = 8,
		-- Allowed height difference between the requested point and the ground hit.
		MaxGroundSnap = 6,
	},

	Defenses = {
		WoodenBarricade = {
			Id = "WoodenBarricade",
			DisplayName = "Wooden Barricade",
			Description = "Cheap wall that holds zombies at the gate.",
			Kind = "Barricade",
			Cost = 50,
			MaxHealth = 350,
			Size = Vector3.new(12, 6, 2),
			Color = Color3.fromRGB(160, 110, 60),
			Material = "WoodPlanks",
			Upgrades = {
				{ Cost = 60, HealthMultiplier = 1.6 },
				{ Cost = 110, HealthMultiplier = 2.4 },
			},
			Icon = "🪵",
			SortOrder = 1,
		},
		IronBarricade = {
			Id = "IronBarricade",
			DisplayName = "Iron Barricade",
			Description = "Heavy wall that takes a beating.",
			Kind = "Barricade",
			Cost = 140,
			MaxHealth = 1000,
			Size = Vector3.new(12, 7, 2.5),
			Color = Color3.fromRGB(120, 125, 140),
			Material = "DiamondPlate",
			Upgrades = {
				{ Cost = 150, HealthMultiplier = 1.5 },
				{ Cost = 260, HealthMultiplier = 2.1 },
			},
			Icon = "🧱",
			SortOrder = 2,
		},
		PumpkinSentry = {
			Id = "PumpkinSentry",
			DisplayName = "Pumpkin Sentry",
			Description = "Spits seed bolts at the nearest enemy, flying ones included.",
			Kind = "Sentry",
			SentryType = "Bolt",
			Cost = 180,
			MaxHealth = 300,
			Size = Vector3.new(4, 6, 4),
			Range = 42,
			Damage = 14,
			FireInterval = 0.7,
			CanTargetAir = true,
			Color = Color3.fromRGB(255, 140, 26),
			Material = "SmoothPlastic",
			Upgrades = {
				{ Cost = 150, HealthMultiplier = 1.3, DamageMultiplier = 1.5, RangeMultiplier = 1.1 },
				{ Cost = 260, HealthMultiplier = 1.6, DamageMultiplier = 2.2, RangeMultiplier = 1.2 },
			},
			Icon = "🎃",
			SortOrder = 3,
		},
		HexLantern = {
			Id = "HexLantern",
			DisplayName = "Hex Lantern",
			Description = "Pulses cold light that chills and chips every ground enemy nearby.",
			Kind = "Sentry",
			SentryType = "Pulse",
			Cost = 160,
			MaxHealth = 220,
			Size = Vector3.new(4, 7, 4),
			Range = 24,
			Damage = 6,
			FireInterval = 2,
			CanTargetAir = false,
			Effect = "Chilled",
			Color = Color3.fromRGB(80, 200, 255),
			Material = "Neon",
			Upgrades = {
				{ Cost = 140, HealthMultiplier = 1.3, DamageMultiplier = 1.5, RangeMultiplier = 1.15 },
			},
			Icon = "🏮",
			SortOrder = 4,
		},
	},

	Items = {
		PumpkinHelmet = {
			Id = "PumpkinHelmet",
			DisplayName = "Pumpkin Helmet",
			Description = "+40 max health for this match.",
			Kind = "Accessory",
			Cost = 120,
			Stats = { MaxHealth = 40 },
			Icon = "⛑️",
			SortOrder = 1,
		},
		SwiftBoots = {
			Id = "SwiftBoots",
			DisplayName = "Swift Boots",
			Description = "+3 walk speed for this match.",
			Kind = "Accessory",
			Cost = 100,
			Stats = { WalkSpeed = 3 },
			Icon = "👢",
			SortOrder = 2,
		},
		LuckyCharm = {
			Id = "LuckyCharm",
			DisplayName = "Lucky Charm",
			Description = "+15% Match Coins from kills for this match.",
			Kind = "Accessory",
			Cost = 150,
			Stats = { CoinMultiplier = 0.15 },
			Icon = "🍀",
			SortOrder = 3,
		},
		HealingTonic = {
			Id = "HealingTonic",
			DisplayName = "Healing Tonic",
			Description = "Instantly restore 60 health.",
			Kind = "Utility",
			Cost = 40,
			HealAmount = 60,
			Cooldown = 15,
			Icon = "❤️",
			SortOrder = 4,
		},
		RepairKit = {
			Id = "RepairKit",
			DisplayName = "Repair Kit",
			Description = "Repair every barricade and sentry by 50% of its max health.",
			Kind = "Utility",
			Cost = 90,
			RepairFraction = 0.5,
			Cooldown = 20,
			Icon = "🔧",
			SortOrder = 5,
		},
	},
}

return TableUtil.DeepFreeze(DefenseConfig)
