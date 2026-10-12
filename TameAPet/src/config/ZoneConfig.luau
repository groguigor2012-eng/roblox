--!strict
-- Map zones. Each zone is a box in the world (Workspace.MapZones.<id>). If a part with the
-- zone's id already exists in Workspace.MapZones (e.g. placed by a level designer in
-- Studio) it is used as-is, including its rotation and size; otherwise one is created from
-- `region` below.
--
-- eggs.weights        egg tier -> weight for this zone (weighted random, server-side)
-- eggs.minActive      the spawner tops up to this immediately
-- eggs.maxActive      hard cap for this zone
-- eggs.spawnInterval  seconds between spawns while between min and max
-- eggs.minSpacing     minimum distance (studs) between any two eggs
-- eggs.despawnSeconds lifetime of an unclaimed egg
-- unlock              nil = open to everyone; otherwise the player must own this zone
--                     unlock (bought in the shop) to hatch eggs, collect items or track
--                     eggs here
-- allowFlight         flying mounts are forced to land while inside a zone without flight

export type ZoneRegion = {
	center: Vector3,
	size: Vector3,
	rotationY: number, -- degrees
}

export type ZoneEggSettings = {
	weights: { [string]: number },
	minActive: number,
	maxActive: number,
	spawnInterval: number,
	minSpacing: number,
	despawnSeconds: number,
}

export type ZoneDefinition = {
	id: string,
	displayName: string,
	theme: string,
	unlock: string?,
	allowFlight: boolean,
	region: ZoneRegion,
	eggs: ZoneEggSettings,
}

local ZoneConfig = {}

ZoneConfig.Zones = {
	{
		id = "Meadow",
		displayName = "Sunny Meadow",
		theme = "Meadow",
		unlock = nil,
		allowFlight = true,
		region = { center = Vector3.new(0, 60, 0), size = Vector3.new(440, 140, 440), rotationY = 0 },
		eggs = {
			weights = { Common = 72, Uncommon = 22, Rare = 5, Epic = 1 },
			minActive = 5,
			maxActive = 9,
			spawnInterval = 8,
			minSpacing = 35,
			despawnSeconds = 300,
		},
	},
	{
		id = "Forest",
		displayName = "Whispering Forest",
		theme = "Forest",
		unlock = nil,
		allowFlight = true,
		region = { center = Vector3.new(480, 60, 0), size = Vector3.new(400, 140, 460), rotationY = 12 },
		eggs = {
			weights = { Common = 45, Uncommon = 35, Rare = 15, Epic = 4, Legendary = 1 },
			minActive = 4,
			maxActive = 8,
			spawnInterval = 10,
			minSpacing = 35,
			despawnSeconds = 300,
		},
	},
	{
		id = "Canyon",
		displayName = "Ember Canyon",
		theme = "Canyon",
		unlock = nil,
		allowFlight = true,
		region = { center = Vector3.new(0, 80, 500), size = Vector3.new(460, 180, 400), rotationY = 0 },
		eggs = {
			weights = { Common = 30, Uncommon = 35, Rare = 25, Epic = 8, Legendary = 2 },
			minActive = 3,
			maxActive = 7,
			spawnInterval = 12,
			minSpacing = 40,
			despawnSeconds = 300,
		},
	},
	{
		id = "Lake",
		displayName = "Moonlit Lake",
		theme = "Lake",
		unlock = "Lake",
		allowFlight = true,
		region = { center = Vector3.new(-480, 60, 0), size = Vector3.new(400, 140, 440), rotationY = 0 },
		eggs = {
			weights = { Uncommon = 40, Rare = 35, Epic = 18, Legendary = 6, Mythical = 1 },
			minActive = 3,
			maxActive = 6,
			spawnInterval = 14,
			minSpacing = 40,
			despawnSeconds = 300,
		},
	},
	{
		id = "Peaks",
		displayName = "Storm Peaks",
		theme = "Peaks",
		unlock = "Peaks",
		allowFlight = true,
		region = { center = Vector3.new(0, 130, -520), size = Vector3.new(460, 280, 420), rotationY = 0 },
		eggs = {
			weights = { Rare = 40, Epic = 35, Legendary = 18, Mythical = 6, Secret = 1 },
			minActive = 3,
			maxActive = 6,
			spawnInterval = 18,
			minSpacing = 45,
			despawnSeconds = 300,
		},
	},
} :: { ZoneDefinition }

-- Zones every new profile starts with.
ZoneConfig.DefaultUnlocked = { "Meadow", "Forest", "Canyon" }

-- Hard caps across the whole server, regardless of zone settings.
ZoneConfig.GlobalMaxEggs = 50
ZoneConfig.GlobalMaxItems = 40

-- Spawn-position search tuning.
ZoneConfig.Placement = {
	attempts = 24,
	maxSlopeDegrees = 38,
	clearanceHeight = 6, -- open space required above a spawn point
	footprint = 3, -- width of the clearance box
}

-- The playable world is bounded by invisible walls this far from the origin.
ZoneConfig.WorldHalfExtent = 900
ZoneConfig.WorldCeilingY = 600

function ZoneConfig.get(zoneId: string): ZoneDefinition?
	for _, zone in ZoneConfig.Zones do
		if zone.id == zoneId then
			return zone
		end
	end
	return nil
end

return ZoneConfig
