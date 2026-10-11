--!strict
-- Collectible attributes, reward rules, pickup distances and presentation.
-- Reward amounts are read on the server from server-owned attributes (or the
-- defaults below); nothing the client sends affects the amount.

local CollectibleConfig = {}

-- Attributes set on each tagged collectible (BasePart or Model).
CollectibleConfig.Attributes = table.freeze({
	-- string, required for persistent items. Unique and stable across versions.
	Id = "CollectibleId",
	-- "Shards" | "PowerOrbs", required.
	Type = "CollectibleType",
	-- positive integer, optional (defaults to DefaultRewards[type]).
	Reward = "RewardAmount",
	-- boolean, optional, default true. false = once per player per server session.
	Persistent = "Persistent",
	-- "PerPlayer" (default) or "Shared".
	Mode = "CollectMode",
	-- number >= 0, Shared mode only. Seconds until the item returns; 0 = never.
	RespawnSeconds = "RespawnSeconds",
	-- boolean, written by the server for Shared items; clients hide when false.
	Available = "Available",
})

CollectibleConfig.DefaultRewards = table.freeze({
	Shards = 1,
	PowerOrbs = 1,
})

-- Upper bound for a single collectible's RewardAmount attribute.
CollectibleConfig.MaxRewardAmount = 1000

CollectibleConfig.Ids = table.freeze({
	MaxLength = 64,
	-- Letters, digits and _ - . : only.
	Pattern = "^[%w_%-%.:]+$",
})

CollectibleConfig.Collection = table.freeze({
	-- Client asks to collect when the root is this close to the item's pivot.
	ClientCollectRadius = 4.5,
	-- Server accepts requests up to this distance (latency and size slack).
	ServerCollectRadius = 10,
	-- How often the client checks proximity.
	ClientCheckInterval = 0.1,
	-- Client stops waiting for a reply after this long and may ask again.
	RequestTimeout = 1.5,
	-- After a rejected request the client waits this long before retrying that item.
	RetryCooldown = 0.75,
	-- Every collectible must be a descendant of Workspace[GameConfig.Folders.Collectibles].
	RequireCollectiblesFolder = true,
	-- Per-player token bucket for CollectRequest.
	RateCapacity = 15,
	RateRefillPerSecond = 10,
})

CollectibleConfig.Visual = table.freeze({
	SpinDegreesPerSecond = 120,
	BobHeight = 0.5,
	BobPeriod = 2.2,
	-- Items farther than this from the camera are not animated.
	AnimationRadius = 220,
	PickupDuration = 0.3,
	PickupScale = 1.8,
	SparkleCount = 16,
	FloatingText = true,
	FloatingTextRise = 3,
	FloatingTextDuration = 0.9,
	Colors = table.freeze({
		Shards = Color3.fromRGB(170, 225, 255),
		PowerOrbs = Color3.fromRGB(255, 196, 92),
	}),
	DisplayNames = table.freeze({
		Shards = "Shard",
		PowerOrbs = "Power Orb",
	}),
})

return table.freeze(CollectibleConfig)
