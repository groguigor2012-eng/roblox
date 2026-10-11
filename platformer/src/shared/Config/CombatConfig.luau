--!strict
-- Right-click attack. Animation only: there is no hitbox, damage, knockback
-- or combat remote. The animation asset itself is AnimationConfig.Attack.

local CombatConfig = {}

CombatConfig.Attack = table.freeze({
	Enabled = true,
	-- Observed with UserInputService and never bound or consumed, so the
	-- default camera keeps turning while the right button is held (same
	-- approach as the jump keys). Presses over buttons, text boxes or other
	-- Active UI, or while typing, are ignored.
	MouseButton = Enum.UserInputType.MouseButton2,
	-- Gamepad button and on-screen "Hit" touch button, bound with
	-- ContextActionService at MovementConfig.Input.ActionPriority.
	GamepadButton = Enum.KeyCode.ButtonR1,
	CreateTouchButton = true,
	-- "Click": attack when the right button is released after a short,
	--          still click, so holding right-click to turn the camera never
	--          attacks (default).
	-- "Press": attack the moment the button goes down (most responsive, but
	--          every camera drag also attacks).
	TriggerMode = "Click" :: "Click" | "Press",
	-- Click mode: longest hold and largest mouse travel that still count as a click.
	ClickMaxHoldTime = 0.3,
	ClickMaxDragPixels = 8,
	-- Seconds from one attack's start until the next may start.
	Cooldown = 0.45,
	-- Swing sound timing for a custom animation WITHOUT an "AttackImpact"
	-- event (seconds after the attack starts). With the event, the sound
	-- plays on it; the procedural punch plays it as the strike begins.
	SwingSoundDelay = 0.1,
	-- Movement states (Types.MovementState) in which attacking is ignored.
	BlockedStates = table.freeze({
		Dead = true,
		GroundPounding = true,
		Landing = true,
	}) :: { [string]: boolean },
	-- Procedural punch used when AnimationConfig.Attack.AnimationId is empty
	-- (or fails to load). Angles are degrees; positive shoulder pitch swings
	-- the arm forward. Phases run in order: wind-up, strike, hold, recovery.
	Fallback = table.freeze({
		WindupTime = 0.09,
		StrikeTime = 0.07,
		HoldTime = 0.05,
		RecoveryTime = 0.18,
		WindupShoulderPitch = -35,
		StrikeShoulderPitch = 95,
		-- R15 only (R6 has no elbow or waist joint).
		WindupElbowBend = 70,
		WindupWaistTwist = -15,
		StrikeWaistTwist = 20,
	}),
})

return table.freeze(CombatConfig)
