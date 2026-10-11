--!strict
-- Every sound the framework plays, in one place. AudioController is the only
-- module that creates or plays these Sounds.
--
-- Assets. No custom audio ships with this project and no asset id here is
-- made up. Two kinds of value are used:
--   ""                silent: the event is fully wired, nothing plays until
--                     you paste "rbxassetid://<number>" of audio you own or
--                     may use (Creator Store audio marked free to use, or
--                     your own uploads)
--   BUILTIN.*         files that ship inside the Roblox client. They are
--                     the exact paths Roblox's own RbxCharacterSounds script
--                     plays, so they exist in every client and need no
--                     permission. They are recoloured here (PlaybackSpeed,
--                     StartTime, MaxDuration) as placeholders and are meant
--                     to be replaced by purpose-made sounds for polish.
--
-- Roblox's own character sounds (RbxCharacterSounds: Running, Jumping,
-- Landing, Died, ...) keep playing unless you configure a replacement:
--   Footsteps.Surfaces has any sound -> default "Running" loop is muted
--   Sounds.Jump has a SoundId         -> default "Jumping" is muted
--   Sounds.Death has a SoundId        -> default "Died" is muted
-- With no footstep sounds configured, the default "Running" loop is kept and
-- retuned by speed instead (quieter and slower when walking).
--
-- Scope:
--   Character  3D sound on the character the event belongs to (local player
--              for abilities; any nearby player for footsteps/jump/death)
--   World      3D sound at a world position (ground-pound impacts)
--   UI         2D sound heard only by the local player (pickups, respawn)
-- Sounds played by a client do not replicate (SoundService.RespectFilteringEnabled),
-- so ability sounds are heard by their player only; footsteps, jumps and deaths
-- of other players are generated locally from their replicated movement, and
-- ground-pound impacts from the server's ImpactEffect broadcast.

export type Scope = "Character" | "World" | "UI"
export type GroupName = "Footsteps" | "Actions" | "Interface"

export type Sound = {
	SoundId: string,
	Scope: Scope,
	Group: GroupName,
	Volume: number,
	PlaybackSpeed: number,
	-- Random +/- fraction applied to PlaybackSpeed each play (0.05 = +/-5%).
	PitchVariance: number,
	RollOffMinDistance: number,
	RollOffMaxDistance: number,
	-- Minimum seconds between two plays of this sound (per character).
	Cooldown: number,
	-- Pooled Sound instances: the most copies that can overlap.
	Voices: number,
	-- Seconds into the file to start from.
	StartTime: number,
	-- > 0: fade out and stop after this many seconds (for slicing longer files).
	MaxDuration: number,
	Looped: boolean,
}

-- Paths used by Roblox's RbxCharacterSounds (verified against its source).
local BUILTIN = table.freeze({
	Jump = "rbxasset://sounds/action_jump.mp3",
	Land = "rbxasset://sounds/action_jump_land.mp3",
	-- Wind/rush; RbxCharacterSounds loops the 2-9 s region of it.
	Wind = "rbxasset://sounds/action_falling.ogg",
	-- RbxCharacterSounds' own footstep loop ("action_footsteps_plastic.mp3")
	-- is retuned in place rather than played from here (Footsteps.DefaultLoop).
})

local DEFAULTS: Sound = {
	SoundId = "",
	Scope = "Character",
	Group = "Actions",
	Volume = 0.5,
	PlaybackSpeed = 1,
	PitchVariance = 0.04,
	RollOffMinDistance = 8,
	RollOffMaxDistance = 90,
	Cooldown = 0.05,
	Voices = 2,
	StartTime = 0,
	MaxDuration = 0,
	Looped = false,
}

local function sound(overrides: { [string]: any }): Sound
	local result = table.clone(DEFAULTS) :: { [string]: any }
	for key, value in overrides do
		assert(DEFAULTS[key :: any] ~= nil, `AudioConfig: unknown sound field {key}`)
		result[key] = value
	end
	return table.freeze(result) :: any
end

local AudioConfig = {}

AudioConfig.Sounds = table.freeze({
	-- Ground jump. Empty: Roblox's default "Jumping" sound plays.
	Jump = sound({ SoundId = "", Volume = 0.5 }),
	-- Second jump: the jump sound pitched up for a lighter, airy accent.
	DoubleJump = sound({ SoundId = BUILTIN.Jump, PlaybackSpeed = 1.4, Volume = 0.55 }),
	-- Short whoosh as the spin starts (a slice of the wind sound).
	SpinWhoosh = sound({
		SoundId = BUILTIN.Wind,
		PlaybackSpeed = 1.8,
		StartTime = 2,
		MaxDuration = 0.45,
		Volume = 0.35,
	}),
	-- Optional sustained air while spinning/floating (looped, stopped when the spin ends).
	SpinAir = sound({ SoundId = "", Looped = true, Volume = 0.2, Voices = 1 }),
	-- Landing after a double jump (plays with the landing dust puff).
	DoubleJumpLanding = sound({ SoundId = BUILTIN.Land, PlaybackSpeed = 1.1, Volume = 0.6 }),
	Dash = sound({
		SoundId = BUILTIN.Wind,
		PlaybackSpeed = 2.6,
		StartTime = 2,
		MaxDuration = 0.28,
		Volume = 0.5,
		Cooldown = 0.1,
	}),
	WallJump = sound({ SoundId = BUILTIN.Jump, PlaybackSpeed = 1.15, Volume = 0.55 }),
	GroundPoundStart = sound({
		SoundId = BUILTIN.Wind,
		PlaybackSpeed = 1.25,
		StartTime = 2,
		MaxDuration = 0.35,
		Volume = 0.45,
	}),
	-- Heavy thud on the same frame as the shockwave: the landing sound slowed down.
	GroundPoundImpact = sound({
		SoundId = BUILTIN.Land,
		Scope = "World",
		PlaybackSpeed = 0.55,
		PitchVariance = 0.03,
		Volume = 1,
		RollOffMinDistance = 12,
		RollOffMaxDistance = 220,
		Voices = 4,
	}),
	-- Right-click swing whoosh (at the "AttackImpact" event or the punch's strike).
	AttackSwing = sound({
		SoundId = BUILTIN.Wind,
		PlaybackSpeed = 3.2,
		StartTime = 2,
		MaxDuration = 0.16,
		Volume = 0.4,
		Cooldown = 0.1,
	}),
	-- Played only after the server confirms the pickup.
	ShardCollect = sound({ SoundId = "", Scope = "UI", Group = "Interface", Volume = 0.45, Voices = 4, Cooldown = 0.03 }),
	PowerOrbCollect = sound({ SoundId = "", Scope = "UI", Group = "Interface", Volume = 0.6, Voices = 2 }),
	Damage = sound({ SoundId = "", Volume = 0.55, Cooldown = 0.15 }),
	-- Empty: Roblox's default "Died" sound plays.
	Death = sound({ SoundId = "", Volume = 0.6 }),
	Respawn = sound({ SoundId = "", Scope = "UI", Group = "Interface", Volume = 0.4 }),
}) :: { [string]: Sound }

-- Shard chime rises a semitone per pickup in quick succession so streaks feel
-- rewarding instead of repetitive: speed = 2^(min(streak, MaxSteps) * Semitones / 12).
AudioConfig.CollectChain = table.freeze({
	Window = 0.7,
	SemitonesPerStep = 1,
	MaxSteps = 7,
})

AudioConfig.Footsteps = table.freeze({
	Enabled = true,
	-- One-shot step sounds per surface; one is picked at random each step
	-- (never the same twice in a row when there are several).
	Surfaces = table.freeze({
		Grass = table.freeze({}),
		Dirt = table.freeze({}),
		Stone = table.freeze({}),
		Wood = table.freeze({}),
		Metal = table.freeze({}),
		Default = table.freeze({}),
	}) :: { [string]: { string } },
	-- Enum.Material name -> surface. Anything unlisted uses Default; an empty
	-- surface also falls back to Default.
	MaterialSurfaces = table.freeze({
		Grass = "Grass",
		LeafyGrass = "Grass",
		Ground = "Dirt",
		Mud = "Dirt",
		Sand = "Dirt",
		Snow = "Dirt",
		Slate = "Stone",
		Rock = "Stone",
		Concrete = "Stone",
		Brick = "Stone",
		Cobblestone = "Stone",
		Granite = "Stone",
		Marble = "Stone",
		Basalt = "Stone",
		Limestone = "Stone",
		Pavement = "Stone",
		Asphalt = "Stone",
		Sandstone = "Stone",
		Wood = "Wood",
		WoodPlanks = "Wood",
		Metal = "Metal",
		DiamondPlate = "Metal",
		CorrodedMetal = "Metal",
		Foil = "Metal",
	}) :: { [string]: string },
	-- Studs travelled per step at walk and run pace (interpolated by speed
	-- across Locomotion.RunBlendStart..RunBlendEnd), so steps speed up as the
	-- character does. Used when the animation has no "Footstep" events.
	WalkStride = 3.2,
	RunStride = 5,
	WalkVolume = 0.3,
	RunVolume = 0.55,
	PitchVariance = 0.08,
	RollOffMinDistance = 5,
	RollOffMaxDistance = 70,
	Voices = 3,
	-- Other players' characters farther than this from the camera are ignored.
	HearingRadius = 90,
	-- After a "Footstep" animation event, distance-based steps pause for this
	-- long (so marker-driven steps never double up with the fallback).
	MarkerSuppressTime = 0.6,
	-- Movement states in which the local player makes footsteps.
	ActiveStates = table.freeze({
		Grounded = true,
	}) :: { [string]: boolean },
	-- Retuning of Roblox's default looped footsteps (used when Surfaces is all empty).
	DefaultLoop = table.freeze({
		WalkPlaybackSpeed = 1.35,
		RunPlaybackSpeed = 1.85,
		WalkVolume = 0.3,
		RunVolume = 0.65,
	}),
})

-- Mixer: all sounds route through SoundGroups under one master with a
-- compressor, so many sounds at once can't stack into clipping.
AudioConfig.Mix = table.freeze({
	MasterVolume = 1,
	FootstepsVolume = 0.8,
	ActionsVolume = 1,
	InterfaceVolume = 0.9,
	CompressorThreshold = -16,
	CompressorRatio = 4,
	CompressorAttack = 0.01,
	CompressorRelease = 0.15,
})

return table.freeze(AudioConfig)
