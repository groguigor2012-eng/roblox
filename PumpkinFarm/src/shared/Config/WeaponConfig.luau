--!strict
--[[
	WeaponConfig
	Path: ReplicatedStorage.Shared.Config.WeaponConfig

	Weapons and class abilities. The server computes every hit from these values;
	clients only send intent (aim point + sequence number).

	Weapon fields:
		Module      Weapon implementation in ServerScriptService.Server.Classes.Weapons
		Damage, Cooldown
		MagicStaff (ProjectileAoE): ProjectileSpeed, ProjectileRadius, MaxRange, AOERadius,
		            MinFalloff (damage fraction at the edge of the blast), DirectHitBonus
		ReaperScythe (MeleeCleave): CleaveRadius, CleaveAngle (full cone, degrees),
		            MaxTargets, Knockback, HitDelay (swing wind-up before damage)
		Animations  asset ids, "" = no animation (hook for the art pipeline)
		Visual      tool model parameters (ModelFactory.CreateWeaponTool)

	Dependencies: Shared.Utilities.TableUtil
]]

local TableUtil = require(script.Parent.Parent.Utilities.TableUtil)

local WeaponConfig = {
	-- Server accepts an attack this many seconds early to absorb network jitter.
	CooldownTolerance = 0.12,
	-- Aim points further than this from the character are rejected as malformed.
	MaxAimDistance = 400,

	Weapons = {
		MagicStaff = {
			Id = "MagicStaff",
			DisplayName = "Magic Staff",
			Module = "MagicStaff",
			Damage = 35,
			Cooldown = 1.2,
			ProjectileSpeed = 110,
			ProjectileRadius = 1,
			MaxRange = 140,
			AOERadius = 12,
			MinFalloff = 0.4,
			DirectHitBonus = 0.25,
			Animations = { Attack = "", Ability = "" },
			Visual = {
				Kind = "Staff",
				Color = Color3.fromRGB(110, 70, 40),
				GlowColor = Color3.fromRGB(120, 255, 150),
			},
		},
		ReaperScythe = {
			Id = "ReaperScythe",
			DisplayName = "Reaper Scythe",
			Module = "ReaperScythe",
			Damage = 75,
			Cooldown = 1.5,
			CleaveRadius = 10,
			CleaveAngle = 150,
			MaxTargets = 8,
			Knockback = 55,
			HitDelay = 0.15,
			Animations = { Attack = "", Ability = "" },
			Visual = {
				Kind = "Scythe",
				Color = Color3.fromRGB(70, 50, 40),
				GlowColor = Color3.fromRGB(255, 150, 40),
			},
		},
	},

	Abilities = {
		HexNova = {
			Id = "HexNova",
			DisplayName = "Hex Nova",
			Description = "Detonates a curse at the aim point, damaging and heavily slowing enemies.",
			Cooldown = 12,
			MaxRange = 90,
			Radius = 16,
			Damage = 25,
			Effect = "Hexed",
		},
		ReapingWhirl = {
			Id = "ReapingWhirl",
			DisplayName = "Reaping Whirl",
			Description = "Spin the scythe in a full circle, hitting and knocking back everything nearby.",
			Cooldown = 10,
			Radius = 14,
			Damage = 110,
			MaxTargets = 16,
			Knockback = 80,
		},
	},
}

return TableUtil.DeepFreeze(WeaponConfig)
