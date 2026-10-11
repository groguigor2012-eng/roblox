--!strict
-- Framework-wide settings shared by server and client: CollectionService tags,
-- folder names, the remote contract, health model, collision groups and
-- security thresholds. Nothing in here is secret; the server never trusts a
-- value just because it appears in a shared module.

local GameConfig = {}

-- CollectionService tags. Only explicitly tagged instances take part in the
-- collectible and destructible systems.
GameConfig.Tags = table.freeze({
	Collectible = "Collectible",
	GroundPoundBreakable = "GroundPoundBreakable",
})

GameConfig.Folders = table.freeze({
	-- Workspace child that every collectible must live under.
	Collectibles = "Collectibles",
	-- Workspace child for breakable level pieces (organisational; the tag is what counts).
	Destructibles = "Destructibles",
	-- Client-only Workspace folder for local visual effects.
	LocalEffects = "LocalEffects",
	-- ReplicatedStorage.Shared child created and verified by the server bootstrap.
	Remotes = "Remotes",
})

-- Remote contract: name -> class. The server creates exactly these and the
-- client refuses to start if any is missing or has the wrong class.
--   CollectRequest    client -> server  (target: Instance)
--   CollectResult     server -> client  (Types.CollectResult)
--   CollectionState   server -> client  (Types.CollectionState)
--   MovementAction    client -> server  (action: Types.MovementAction, poundId: number?)
--   GroundPoundImpact client -> server  (poundId: number, impactPosition: Vector3)
--   ImpactEffect      server -> clients (Types.ImpactEffect)
GameConfig.Remotes = table.freeze({
	CollectRequest = "RemoteEvent",
	CollectResult = "RemoteEvent",
	CollectionState = "RemoteEvent",
	MovementAction = "RemoteEvent",
	GroundPoundImpact = "RemoteEvent",
	ImpactEffect = "RemoteEvent",
}) :: { [string]: string }

-- Seconds the client waits for the server-created remotes before giving up.
GameConfig.RemoteWaitTimeout = 30

GameConfig.Health = table.freeze({
	-- Humanoid.MaxHealth applied by the server to every spawned character.
	MaxHealth = 100,
})

-- Server-registered collision groups (PhysicsService). Client-side debris uses
-- VisualDebris, which never collides with characters or with itself.
GameConfig.CollisionGroups = table.freeze({
	Characters = "PlatformerCharacters",
	VisualDebris = "PlatformerVisualDebris",
})

-- Attributes read from parts tagged GroundPoundBreakable. All are optional.
GameConfig.DestructibleAttributes = table.freeze({
	-- boolean, default true. false makes a tagged part immune to ground pounds.
	BreakOnGroundPound = "BreakOnGroundPound",
	-- number, default 0. Minimum server-measured fall distance (studs) of the pound.
	MinPower = "GroundPoundMinPower",
	-- integer >= 1, default 1. Qualifying impacts needed before the part breaks.
	BreakHits = "BreakHits",
	-- number >= 0, default 0. Seconds until a broken part is restored; 0 = permanent.
	RespawnSeconds = "RespawnSeconds",
})

GameConfig.Progression = table.freeze({
	-- Server systems allowed to grant currency through ProgressionService.
	TrustedRewardSources = table.freeze({
		Collectible = true,
	}),
})

GameConfig.Security = table.freeze({
	-- Log a warning when a player's violation score reaches a multiple of this.
	ViolationWarnThreshold = 5,
	-- Kick when the score reaches this. 0 disables kicking (log only).
	ViolationKickThreshold = 0,
	-- One violation point decays every this many seconds.
	ViolationDecaySeconds = 30,
})

GameConfig.Debug = table.freeze({
	-- Prints Debug-level log lines (expected rejections, registrations).
	VerboseLogging = false,
})

-- Test course built by the server at startup.
--   "Always"     build in every server (default, so a fresh place is playable)
--   "StudioOnly" build only in Studio play sessions
--   "Off"        never build; use this once real levels exist
GameConfig.DemoCourse = table.freeze({
	Mode = "Always" :: "Always" | "StudioOnly" | "Off",
	Origin = Vector3.new(0, 0, 0),
	DamagePadDamage = 20,
	HealPadAmount = 25,
	PadCooldown = 1,
})

return table.freeze(GameConfig)
