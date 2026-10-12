--!strict
-- Mount movement tuning. The speed formula itself lives in
-- ServerScriptService.Services.MountStats (owned by MountService).

local MountConfig = {}

-- Speed formula inputs (see MountStats.computeSpeed).
MountConfig.MaxMountSpeed = 140 -- studs/second, absolute cap
MountConfig.UpgradeBonusPerLevel = 0.06 -- +6% per Saddle Upgrade level

-- Handling.
MountConfig.TurnRateDegrees = 140 -- yaw degrees per second at full steer (ground)
MountConfig.AirTurnRateDegrees = 110
MountConfig.Acceleration = 70 -- studs/s^2 when speeding up
MountConfig.Deceleration = 110 -- studs/s^2 when slowing down
MountConfig.ReverseFactor = 0.4 -- backwards speed relative to forward speed
MountConfig.JumpVelocity = 55
MountConfig.DoubleJumpVelocity = 48
MountConfig.MaxAirJumps = 1 -- for pets with "DoubleJump"
MountConfig.BankAngleDegrees = 18 -- visual roll while turning in the air
MountConfig.PitchAngleDegrees = 12 -- visual pitch while climbing/diving

-- Flight.
MountConfig.AscendSpeed = 38
MountConfig.DescendSpeed = 48
MountConfig.VerticalAcceleration = 80
MountConfig.MaxFlightAltitude = 320 -- studs above the ground directly below
MountConfig.LandingHeight = 1.5 -- landing happens within this gap above the ground

-- Physics constraint strength.
MountConfig.MaxForce = 4e5
MountConfig.MaxTorque = 4e5
MountConfig.OrientationResponsiveness = 18

-- Network: movement intent from the rider.
MountConfig.InputSendRate = 15 -- max packets per second from a client
MountConfig.InputKeepAlive = 0.2 -- resend unchanged input this often
MountConfig.InputStaleSeconds = 0.6 -- server zeroes input older than this

-- Network ownership. "Server" = the server simulates the mount (secure, input has one
-- round-trip of latency). This is the only supported mode; see docs/ARCHITECTURE.md.
MountConfig.NetworkOwnership = "Server"

-- Server sanity checks applied every step.
MountConfig.Sanity = {
	SpeedTolerance = 1.35, -- measured speed may exceed the cap by this factor before clamping
	KillHeightMargin = 40, -- dismount when this close to FallenPartsDestroyHeight
}

MountConfig.SummonCooldown = 1.5 -- seconds between summons
MountConfig.DismountLift = 4 -- studs the rider is lifted when dismounting

return MountConfig
