--!strict
--[[
	StatusEffectConfig
	Path: ReplicatedStorage.Shared.Config.StatusEffectConfig

	Timed effects applied by StatusEffectService to players and enemies.

	Fields:
		Duration                 default seconds (callers may override)
		SpeedMultiplier          multiplies movement speed (0 = rooted)
		AttackSpeedMultiplier    > 1 means faster attacks (enemy cooldowns are divided by it)
		DamageTakenMultiplier    multiplies incoming damage
		BlocksAttacks, BlocksJump
		Stacking  "Refresh"  re-applying resets the timer, keeps the strongest magnitude
		          "Ignore"   re-applying while active is rejected (no stun-locking)
		          "Extend"   adds duration up to MaxDuration
		ImmunityDuration         after expiry the target cannot receive it again for this long
		Targets                  which target kinds may receive it

	Dependencies: Shared.Utilities.TableUtil
]]

local TableUtil = require(script.Parent.Parent.Utilities.TableUtil)

export type EffectDefinition = {
	Id: string,
	DisplayName: string,
	Duration: number,
	SpeedMultiplier: number?,
	AttackSpeedMultiplier: number?,
	DamageTakenMultiplier: number?,
	BlocksAttacks: boolean?,
	BlocksJump: boolean?,
	Stacking: string,
	MaxDuration: number?,
	ImmunityDuration: number?,
	Targets: { Player: boolean?, Enemy: boolean? },
	Icon: string,
	IsBuff: boolean?,
}

local Effects: { [string]: EffectDefinition } = {
	Stunned = {
		Id = "Stunned",
		DisplayName = "Stunned",
		Duration = 2,
		SpeedMultiplier = 0,
		BlocksAttacks = true,
		BlocksJump = true,
		Stacking = "Ignore",
		ImmunityDuration = 1.5,
		Targets = { Player = true },
		Icon = "💫",
	},
	Slowed = {
		Id = "Slowed",
		DisplayName = "Slowed",
		Duration = 3,
		SpeedMultiplier = 0.55,
		Stacking = "Refresh",
		Targets = { Player = true },
		Icon = "🧪",
	},
	Hexed = {
		Id = "Hexed",
		DisplayName = "Hexed",
		Duration = 3,
		SpeedMultiplier = 0.5,
		Stacking = "Refresh",
		Targets = { Enemy = true },
		Icon = "🔮",
	},
	Chilled = {
		Id = "Chilled",
		DisplayName = "Chilled",
		Duration = 2.5,
		SpeedMultiplier = 0.7,
		Stacking = "Refresh",
		Targets = { Enemy = true },
		Icon = "❄️",
	},
	BossAura = {
		Id = "BossAura",
		DisplayName = "Harvester's Aura",
		Duration = 0.75,
		SpeedMultiplier = 1.35,
		AttackSpeedMultiplier = 1.2,
		Stacking = "Refresh",
		Targets = { Enemy = true },
		Icon = "🔥",
		IsBuff = true,
	},
	SpawnProtection = {
		Id = "SpawnProtection",
		DisplayName = "Protected",
		Duration = 3,
		DamageTakenMultiplier = 0,
		Stacking = "Refresh",
		Targets = { Player = true },
		Icon = "🛡️",
		IsBuff = true,
	},
}

local StatusEffectConfig = {
	Effects = Effects,
	-- How often StatusEffectService sweeps for expired effects.
	TickInterval = 0.1,
	-- While stunned, a character that moves further than this from where the stun
	-- started is snapped back (defeats client-side WalkSpeed overrides).
	StunMaxDisplacement = 4,
}

function StatusEffectConfig.Get(effectId: string): EffectDefinition?
	return Effects[effectId]
end

return TableUtil.DeepFreeze(StatusEffectConfig)
