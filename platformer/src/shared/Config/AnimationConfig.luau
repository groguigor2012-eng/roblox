--!strict
-- Every animation the framework plays, in one place. AnimationController is
-- the only module that loads or plays these.
--
-- Layering (higher priority wins on the joints it keys):
--   Core      Roblox's Animate script: idle, walk, run, jump, fall, climb,
--             swim, sit, emotes, tools. Always running underneath.
--   Idle      custom idle (only if Locomotion.Idle.AnimationId is set)
--   Movement  AnimationController's walk/run layer (speed-matched, blended)
--   Action    ability and attack animations (dash roll, spin pose, attack)
-- So abilities always override locomotion, and locomotion overrides the
-- defaults, without any two systems playing on the same priority.
--
-- Assets: no custom animation ships with this project. Empty ids mean:
--   Locomotion.Walk / Run  reuse the walk/run asset the character's own
--                          Animate script already loads (Roblox's default, or
--                          the player's avatar animation pack), read at spawn
--   Locomotion.Idle        leave idle to Animate (keeps /e emotes working)
--   Attack                 procedural punch (CombatConfig.Attack.Fallback)
--   DoubleJumpSpin         no pose; the spin itself is physical rotation
--   DashRoll               dash with trail/dust only
--
-- To use your own animation: make it in the Animation Editor (or use one you
-- own / may use), publish it under the same owner as the experience (your
-- account or the owning group), and paste "rbxassetid://<number>" here.
-- Animations owned by someone else will not load in your game. An id that
-- fails to load is reported once and its fallback is used for the session.
-- R15 animations don't play on R6 rigs and vice versa.
--
-- Markers: name the animation events your asset contains (Animation Editor ->
-- right-click the timeline -> Add Animation Event). Only listed names are
-- listened for; assets without them fall back to timing-based sounds.

export type Entry = {
	AnimationId: string,
	Priority: Enum.AnimationPriority,
	-- Playback speed multiplier (2 = twice as fast).
	Speed: number,
	-- Blend-in / blend-out time in seconds.
	FadeTime: number,
	Looped: boolean,
	-- Animation event names to listen for on this track.
	Markers: { string },
}

export type LocomotionEntry = {
	-- Empty: reuse the Animate script's asset (Walk/Run) or leave it to Animate (Idle).
	AnimationId: string,
	Priority: Enum.AnimationPriority,
	-- Ground speed (studs/s, at the default character size) at which the
	-- animation plays at speed 1. Playback speed = groundSpeed / ReferenceSpeed.
	ReferenceSpeed: number,
	Markers: { string },
}

local AnimationConfig = {}

-- Right-click attack. Author it with a wind-up, hit and recovery; an
-- "AttackImpact" event times the swing sound to the contact frame.
AnimationConfig.Attack = table.freeze({
	AnimationId = "",
	Priority = Enum.AnimationPriority.Action,
	Speed = 1,
	FadeTime = 0.05,
	Looped = false,
	Markers = table.freeze({ "AttackImpact" }),
}) :: Entry

-- Optional pose (e.g. tucked knees) held while the double-jump spin runs.
AnimationConfig.DoubleJumpSpin = table.freeze({
	AnimationId = "",
	Priority = Enum.AnimationPriority.Action,
	Speed = 1,
	FadeTime = 0.12,
	Looped = true,
	Markers = table.freeze({}),
}) :: Entry

-- Optional dash roll.
AnimationConfig.DashRoll = table.freeze({
	AnimationId = "",
	Priority = Enum.AnimationPriority.Action,
	Speed = 1.6,
	FadeTime = 0.05,
	Looped = false,
	Markers = table.freeze({}),
}) :: Entry

-- Walk/run/idle layer driven by the character's real ground speed.
--   moving   starts above MoveStartSpeed, stops below MoveStopSpeed (hysteresis)
--   blend    run weight = clamp((speed - RunBlendStart) / (RunBlendEnd - RunBlendStart), 0, 1)
--            walk weight = 1 - run weight
--   timewarp playback speed = speed / (ReferenceSpeed * sizeScale), clamped
--            to [MinPlaybackSpeed, MaxPlaybackSpeed]; sizeScale = HipHeight /
--            DefaultHipHeight on R15 (scaled avatars), 1 on R6
-- With the default WalkSpeed of 16, keyboard movement is a run; walking
-- shows with partial gamepad/thumbstick input or a lower WalkSpeed.
AnimationConfig.Locomotion = table.freeze({
	Enabled = true,
	Walk = table.freeze({
		AnimationId = "",
		Priority = Enum.AnimationPriority.Movement,
		ReferenceSpeed = 8,
		Markers = table.freeze({ "Footstep" }),
	}) :: LocomotionEntry,
	Run = table.freeze({
		AnimationId = "",
		Priority = Enum.AnimationPriority.Movement,
		ReferenceSpeed = 16,
		Markers = table.freeze({ "Footstep" }),
	}) :: LocomotionEntry,
	Idle = table.freeze({
		AnimationId = "",
		Priority = Enum.AnimationPriority.Idle,
		ReferenceSpeed = 1,
		Markers = table.freeze({}),
	}) :: LocomotionEntry,
	FadeTime = 0.2,
	MoveStartSpeed = 0.8,
	MoveStopSpeed = 0.4,
	RunBlendStart = 10,
	RunBlendEnd = 14,
	MinPlaybackSpeed = 0.5,
	MaxPlaybackSpeed = 1.6,
	DefaultHipHeight = 2,
	-- Movement states (Types.MovementState) in which the layer may play.
	-- Everything else (abilities, air, death) fades it out; Animate's
	-- jump/fall and the ability animations take over.
	ActiveStates = table.freeze({
		Grounded = true,
	}) :: { [string]: boolean },
})

return table.freeze(AnimationConfig)
