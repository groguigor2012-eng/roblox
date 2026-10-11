--!strict
-- Every tunable number for the platformer move set. The client uses these to
-- simulate movement; the server uses the same values (plus the Validation
-- tolerances) to judge whether reported actions are plausible.
--
-- Units: studs, seconds, studs/second. Speeds are applied as velocities, not
-- forces, so they behave the same regardless of character mass.

export type CurveName = "Linear" | "QuadOut" | "CubicOut" | "Smoothstep" | "ExpoOut"

local MovementConfig = {}

MovementConfig.Input = table.freeze({
	JumpKeys = table.freeze({ Enum.KeyCode.Space, Enum.KeyCode.ButtonA }),
	DashKeys = table.freeze({ Enum.KeyCode.E, Enum.KeyCode.ButtonX }),
	GroundPoundKeys = table.freeze({ Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonB }),
	-- ContextActionService priority for Dash/GroundPound. Above Default so
	-- LeftShift reaches us before the shift-lock toggle; the input is only
	-- sunk when the ability actually starts. (Jump keys are observed with
	-- UserInputService and never bound, so default jumping is untouched.)
	ActionPriority = Enum.ContextActionPriority.High.Value,
	-- Adds on-screen Dash / Pound buttons on touch devices.
	CreateTouchButtons = true,
	-- Touch jump arrives as a stream of JumpRequest events while held. A request
	-- counts as a new press only after this much silence.
	TouchJumpRepeatWindow = 0.15,
})

MovementConfig.Physics = table.freeze({
	-- Force cap for the single LinearVelocity each character owns. High enough
	-- to beat Humanoid control and gravity for any rig size.
	ConstraintMaxForce = 1e6,
})

MovementConfig.Grounding = table.freeze({
	-- After walking (not jumping) off a ledge, a jump within this window is an
	-- ordinary ground jump and does not use up the double jump.
	CoyoteTime = 0.12,
})

MovementConfig.DoubleJump = table.freeze({
	Enabled = true,
	-- Vertical velocity (studs/s) set by the air jump. It replaces the current
	-- vertical velocity, so the jump has the same height while rising or falling.
	Velocity = 52,
	-- Air jumps available between landings.
	MaxAirJumps = 1,
	Effects = table.freeze({
		TrailDuration = 0.35, -- how long the trail emits after the jump
		TrailLifetime = 0.3, -- Trail.Lifetime (segment fade time)
		TrailWidth = 1.4,
		TrailColor = Color3.fromRGB(235, 240, 255),
		TrailTransparency = NumberSequence.new(0.15, 1),
		BurstCount = 18,
		ParticleColor = Color3.fromRGB(28, 32, 44),
		ParticleLifetime = NumberRange.new(0.25, 0.45),
		ParticleSize = NumberSequence.new(0.7, 0),
		ParticleSpeed = NumberRange.new(6, 12),
		ParticleTransparency = NumberSequence.new(0.1, 1),
	}),
})

-- Spin + float added to every double jump (not to wall jumps).
--   Upward boost: the air jump's vertical velocity becomes
--     DoubleJump.Velocity + UpwardBoost.
--   Spin: yaw rate over normalised spin time s in [0, 1]
--     omega(s) = SpinSpeed * sin(pi * s)          (degrees/second)
--   eases in and out, so the turn starts and ends gently; total turn is
--     SpinSpeed * SpinDuration * 2/pi degrees (760 * 0.75 * 0.637 ~ 363 deg).
--   Float: while the window is open and the character is moving down (or
--   slower than FloatBelowVerticalSpeed upward), an upward force cancels
--   part of gravity, so the effective downward acceleration is
--     g * (1 - (1 - FallGravityScale) * fade(t))
--   where fade is 1 until the last FloatFadeTime seconds and then drops
--   linearly to 0. Gravity is never cancelled completely and the window
--   always closes, so this can't be used to fly.
MovementConfig.SpinFloat = table.freeze({
	Enabled = true,
	UpwardBoost = 8,
	-- Peak yaw speed in degrees/second; lower = slower spin.
	SpinSpeed = 760,
	SpinDuration = 0.75,
	-- +1 counter-clockwise seen from above, -1 clockwise.
	SpinDirection = 1,
	FloatDuration = 0.9,
	-- Fraction of gravity felt while floating (0.35 = 35%). 1 disables the float.
	FallGravityScale = 0.35,
	FloatFadeTime = 0.25,
	-- The float starts helping once upward speed drops below this (studs/s),
	-- i.e. around the top of the jump, so it lengthens the hang instead of
	-- making the jump taller.
	FloatBelowVerticalSpeed = 10,
	-- Torque cap for the spin constraint (high enough for any rig).
	MaxTorque = 1e6,
	-- The double-jump trail keeps emitting for the whole spin.
	TrailFollowsSpin = true,
})

-- Dash speed over normalised time t in [0, 1]:
--   speed(t) = InitialSpeed + (TerminalSpeed - InitialSpeed) * curve(t)
-- with curve one of (all map 0 -> 0 and 1 -> 1, monotonic):
--   Linear      t
--   QuadOut     1 - (1 - t)^2
--   CubicOut    1 - (1 - t)^3
--   Smoothstep  3t^2 - 2t^3
--   ExpoOut     1 - 2^(-10t)   (exactly 1 at t = 1)
MovementConfig.Dash = table.freeze({
	Enabled = true,
	Duration = 0.28,
	InitialSpeed = 95,
	TerminalSpeed = 34,
	Curve = "QuadOut" :: CurveName,
	-- Measured from dash start.
	Cooldown = 0.75,
	AllowOnGround = true,
	AllowInAir = true,
	MaxAirDashes = 1,
	-- Air dash cancels downward velocity so the dash reads as a short hover.
	ResetFallSpeedInAir = true,
	-- Pressing jump during a dash ends it (on the ground: normal jump; in the air: air jump).
	CancelOnJump = true,
	-- The optional roll animation is AnimationConfig.DashRoll.
	Effects = table.freeze({
		TrailColor = Color3.fromRGB(150, 205, 255),
		TrailTransparency = NumberSequence.new(0.3, 1),
		TrailLifetime = 0.25,
		DustCount = 12,
	}),
})

-- Ground pound: brief hang ("windup"), then a straight vertical descent.
-- Descent speed after d seconds of falling:
--   v(d) = min(MaxDescentSpeed, InitialDescentSpeed + DescentAcceleration * d)
MovementConfig.GroundPound = table.freeze({
	Enabled = true,
	-- Feet must be at least this high above the ground to start.
	MinActivationHeight = 6,
	WindupTime = 0.12,
	InitialDescentSpeed = 60,
	DescentAcceleration = 400,
	MaxDescentSpeed = 140,
	-- A pound that has not landed after this long is cancelled (bottomless pit).
	MaxDescentTime = 2.5,
	-- Movement is held still for this long after impact.
	RecoveryTime = 0.18,
	-- Extra probe length below the feet when looking for the landing surface.
	LandingProbeMargin = 0.75,
	-- Server-side break radius around the validated impact point.
	ImpactRadius = 10,
	CameraShakeTrauma = 0.45,
	Shockwave = table.freeze({
		Radius = 12,
		Thickness = 0.35,
		Duration = 0.45,
		Color = Color3.fromRGB(20, 22, 32),
		StartTransparency = 0.2,
		RimColor = Color3.fromRGB(225, 232, 255),
		RimStartTransparency = 0.35,
	}),
	ImpactParticleCount = 26,
	ImpactParticleColor = Color3.fromRGB(24, 26, 36),
	-- Client-only debris chunks per broken part (capped per impact), and their lifetime.
	DebrisChunksPerPart = 6,
	MaxDebrisChunksPerImpact = 60,
	DebrisLifetime = 2.2,
})

MovementConfig.WallJump = table.freeze({
	Enabled = true,
	-- Ray length from the root centre. Root half-width is ~1, so this reaches
	-- walls about 2 studs from the character's side.
	ProbeDistance = 3.2,
	-- Evenly spaced horizontal rays in addition to the movement direction.
	ProbeDirections = 8,
	-- Vertical offsets from the root for each ring of rays.
	ProbeHeightOffsets = table.freeze({ 0, -1.2 }),
	-- Surfaces whose normal has |Y| above this are floors/ceilings, not walls.
	MaxWallNormalY = 0.35,
	-- Launch direction = unit(normalXZ * HorizontalWeight + up * VerticalWeight).
	HorizontalWeight = 1,
	VerticalWeight = 1.25,
	LaunchSpeed = 62,
	-- Horizontal launch velocity is held for this long so steering input
	-- cannot immediately pull the character back into the wall.
	ControlLockTime = 0.2,
	Cooldown = 0.2,
	-- The same wall (same part, normals within SameWallNormalDot) cannot be
	-- reused within this window. Landing clears it.
	SameWallCooldown = 0.6,
	SameWallNormalDot = 0.85,
	-- A wall jump gives back the air jump.
	RestoresDoubleJump = true,
	-- Add the wall's own horizontal velocity (moving platforms).
	InheritWallVelocity = true,
	FaceAwayFromWall = true,
})

-- Server-side plausibility checks. Movement is simulated by the client (it
-- owns its character's physics), so these bound what the server accepts
-- rather than re-simulate it.
MovementConfig.Validation = table.freeze({
	-- Per-player token bucket for MovementAction / GroundPoundImpact.
	RateCapacity = 12,
	RateRefillPerSecond = 8,
	-- Actions may arrive this much earlier than their cooldown (network jitter).
	CooldownTolerance = 0.12,
	-- Minimum spacing between reported air jumps.
	DoubleJumpMinInterval = 0.12,
	-- Lets the server's (lagged) view of the root sit lower than the client's.
	ActivationHeightTolerance = 2.5,
	-- Max distance between reported impact and server-observed root, plus
	-- MaxDescentSpeed * ping.
	ImpactPositionTolerance = 14,
	-- Max horizontal drift between pound start and impact, plus
	-- ImpactHorizontalSpeedAllowance * ping (the server's start position lags).
	ImpactHorizontalTolerance = 10,
	ImpactHorizontalSpeedAllowance = 40,
	-- Impact may be at most this far above the server-observed start height.
	ImpactVerticalTolerance = 4,
	-- Server looks this far below the reported impact for solid ground.
	ImpactGroundProbeDistance = 10,
	-- Extra seconds allowed beyond windup + MaxDescentTime.
	LatencyGrace = 0.35,
	-- Ping is clamped to this when widening tolerances.
	MaxPingAllowance = 0.5,
	MaxBreaksPerImpact = 24,
	-- Players farther than this from an impact do not receive its effect.
	ImpactEffectReplicationRadius = 300,
})

return table.freeze(MovementConfig)
