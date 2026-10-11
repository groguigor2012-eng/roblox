--!strict
-- Every custom animation asset the framework can play, in one place.
--
-- AnimationId is empty by default: no asset ships with this project. Each
-- entry has a working fallback, so leaving an id empty is fine:
--   Attack          procedural right-arm punch (CombatConfig.Attack.Fallback)
--   DoubleJumpSpin  the spin itself is physical rotation; no pose is added
--   DashRoll        the dash still runs with its trail and dust burst
--
-- To use your own animation: create it in the Animation Editor (or use one
-- you own / have permission to use), publish it to Roblox under the same
-- owner as the experience (your account, or the group that owns the game),
-- and paste its id here as "rbxassetid://<number>". Animations owned by
-- someone else will not load in your game. An id that fails to load is
-- reported once in the output and the fallback is used for the session.
--
-- Priority: Action layers over idle/walk/jump/fall (Core, Idle, Movement)
-- and only overrides the joints the animation actually keys. Animate only
-- the upper body for the attack so the legs keep running underneath it.
-- Rig: an animation authored for R15 does not play on R6 and vice versa.

export type Entry = {
	AnimationId: string,
	Priority: Enum.AnimationPriority,
	-- Playback speed multiplier (2 = twice as fast).
	Speed: number,
	-- Blend-in / blend-out time in seconds.
	FadeTime: number,
	Looped: boolean,
}

local AnimationConfig = {}

-- Right-click attack. Author it with a wind-up, hit and recovery.
AnimationConfig.Attack = table.freeze({
	AnimationId = "",
	Priority = Enum.AnimationPriority.Action,
	Speed = 1,
	FadeTime = 0.05,
	Looped = false,
}) :: Entry

-- Optional pose (e.g. tucked knees) held while the double-jump spin runs.
-- Looped; it is stopped when the spin ends.
AnimationConfig.DoubleJumpSpin = table.freeze({
	AnimationId = "",
	Priority = Enum.AnimationPriority.Action,
	Speed = 1,
	FadeTime = 0.12,
	Looped = true,
}) :: Entry

-- Optional dash roll (moved here from MovementConfig.Dash.RollAnimationId).
AnimationConfig.DashRoll = table.freeze({
	AnimationId = "",
	Priority = Enum.AnimationPriority.Action,
	Speed = 1.6,
	FadeTime = 0.05,
	Looped = false,
}) :: Entry

return table.freeze(AnimationConfig)
