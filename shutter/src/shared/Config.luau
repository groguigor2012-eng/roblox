--!strict
-- THE SHUTTER: every tuning value in one place.
-- Shared by server and client. The SERVER is the authority for every value that
-- matters (speed, battery, observation); the client only reads these to draw UI
-- and to predict the battery bar between server updates.

local Config = {}

-- Build the small test map (server/DemoLevel) when the place has no CameraOnly content.
Config.DEMO_LEVEL = true

-- CollectionService tags ---------------------------------------------------------
Config.Tags = {
	CameraOnly = "CameraOnly", -- visible ONLY through the camcorder (doors, clues, anomalies, the Watcher)
	NakedEyeOnly = "NakedEyeOnly", -- visible ONLY to the naked eye (the "pristine" layer that hides what is real)
	Entity = "ShutterEntity", -- a Watcher model driven by WatcherService
	Door = "ShutterDoor", -- hidden door that opens when its CameraOnly prompt is used
	Pickup = "ShutterPickup", -- collectible (clue / battery) behind a CameraOnly prompt
	WatcherSpawn = "WatcherSpawn", -- optional BasePart(s) marking where Watchers (re)spawn
}

-- Player attributes (written by the server only; clients read them) ------------------
Config.Attributes = {
	Battery = "ShutterBattery", -- number 0..MAX_BATTERY
	CamcorderRaised = "ShutterCamcorder", -- boolean
	Sprinting = "ShutterSprinting", -- boolean
	Clues = "ShutterClues", -- number of clues collected
	-- On Watcher models:
	WatcherState = "WatcherState", -- "Idle" | "Stalking" | "Hunting" | "Frozen" | "Cooldown"
	WatcherFrozen = "WatcherFrozen", -- boolean
}

-- Remote names (ReplicatedStorage > Shutter > Remotes) --------------------------------
Config.Remotes = {
	CamcorderToggle = "CamcorderToggle", -- RemoteEvent, client -> server: (wantRaised: boolean)
	SprintState = "SprintState", -- RemoteEvent, client -> server: (wantSprint: boolean)
	LookUpdate = "LookUpdate", -- UnreliableRemoteEvent, client -> server: (lookDirection: Vector3)
	WatcherFeedback = "WatcherFeedback", -- RemoteEvent, server -> client: (kind: string, data: any)
}

-- Movement (studs / second) -------------------------------------------------------------
Config.Movement = {
	WALK_SPEED = 16,
	SPRINT_SPEED = 23,
	CAMCORDER_SPEED = 9,
	SPRINT_REQUEST_RATE = 12, -- max sprint packets per second before they are ignored
	-- Server-side speed sanity check (catches clients that rewrite their own WalkSpeed).
	ANTI_SPEED_ENABLED = true,
	ANTI_SPEED_INTERVAL = 0.5, -- seconds between position samples
	ANTI_SPEED_TOLERANCE = 1.6, -- multiplier on the allowed speed (absorbs network jitter)
	ANTI_SPEED_SLACK = 4, -- extra studs allowed per sample
	ANTI_SPEED_STRIKES = 3, -- consecutive bad samples before rubber-banding
}

-- Camcorder & battery ---------------------------------------------------------------------
Config.Camcorder = {
	MAX_BATTERY = 100,
	DRAIN_PER_SECOND = 10, -- while raised
	RECHARGE_PER_SECOND = 3, -- while lowered...
	RECHARGE_DELAY = 1.5, -- ...after being lowered for this long
	MIN_BATTERY_TO_RAISE = 5, -- stops raise/drop flicker at an empty battery
	TOGGLE_COOLDOWN = 0.25, -- seconds between accepted raise/lower requests
	BATTERY_REPLICATE_INTERVAL = 0.2, -- how often the Battery attribute is pushed to clients
	RESET_BATTERY_ON_SPAWN = true,

	-- Look direction (needed to know what a player is filming)
	LOOK_SEND_RATE = 15, -- client packets per second while raised
	LOOK_MAX_RATE = 40, -- server drops packets above this rate
	LOOK_MAX_AGE = 0.4, -- a look sample older than this is ignored (no free "frozen" watcher)
	LOOK_MAX_BODY_YAW = 75, -- degrees; while filming the body faces the camera (first person)

	-- Client presentation
	FILM_FIELD_OF_VIEW = 55,
	NAKED_FIELD_OF_VIEW = 70,
	FORCE_FIRST_PERSON_WHILE_FILMING = true,
}

-- Interaction with CameraOnly prompts ------------------------------------------------------
Config.Interaction = {
	EXTRA_DISTANCE = 2, -- server allows prompt.MaxActivationDistance + this
	MAX_LOOK_ANGLE = 70, -- degrees between the player's view and the object
	DEBOUNCE = 0.5, -- seconds per player per prompt
	DEFAULT_BATTERY_PICKUP = 35,
	DOOR_FADE_TIME = 0.6,
}

-- THE WATCHER -------------------------------------------------------------------------------
Config.Watcher = {
	AUTO_SPAWN_IF_MISSING = true, -- build a default Watcher rig if no ShutterEntity exists
	THINK_RATE = 20, -- AI / observation ticks per second

	STALK_SPEED = 11, -- far away and unobserved
	HUNT_SPEED = 18, -- close: faster than walking (16), slower than sprinting (23)
	HUNT_RANGE = 45, -- switch from stalking to hunting inside this distance
	DETECT_RANGE = 260, -- ignores players farther than this
	CATCH_RANGE = 3.5, -- horizontal distance that counts as a catch
	CATCH_HEIGHT = 7, -- max vertical difference for a catch
	CATCH_DAMAGE = 100, -- 100 = instant death on a default 100 HP humanoid
	COOLDOWN_AFTER_CATCH = 6,

	-- Observation: "look to survive"
	VIEW_RANGE = 160, -- a camcorder cannot freeze it from farther than this
	VIEW_HALF_ANGLE = 34, -- degrees; the cone the camcorder must point within
	MIN_FREEZE_HOLD = 0.15, -- seconds it stays frozen after the last observation (anti-flicker)

	-- Pathfinding
	PATH_REFRESH = 0.6, -- seconds between path recomputes while chasing
	PATH_REPATH_DISTANCE = 6, -- recompute early if the target moved this far
	AGENT_RADIUS = 2,
	AGENT_HEIGHT = 8,

	-- Relocation: it is never really far behind you
	RELOCATE_DISTANCE = 180,
	RELOCATE_COOLDOWN = 20,
	RELOCATE_MIN = 40,
	RELOCATE_MAX = 65,

	-- Fallback spawn if there is no WatcherSpawn part: this far from the first SpawnLocation
	FALLBACK_SPAWN_OFFSET = Vector3.new(0, 0, -90),
}

-- Client FX ----------------------------------------------------------------------------------
Config.FX = {
	STATIC_START_DISTANCE = 70, -- camcorder interference begins inside this range
	-- Optional sound ids ("rbxassetid://..."); leave "" to skip.
	CAMCORDER_ON_SOUND = "",
	CAMCORDER_OFF_SOUND = "",
	STATIC_LOOP_SOUND = "",
	JUMPSCARE_SOUND = "",
}

return Config
