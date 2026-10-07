--!strict
--[[
	NetworkConfig
	Path: ReplicatedStorage.Shared.Config.NetworkConfig

	Single source of truth for every RemoteEvent / RemoteFunction. RemoteService creates
	the instances under ReplicatedStorage.Remotes from this table at server start; the
	client Net module looks them up by the same names.

	Per remote:
		Class      "RemoteEvent" | "RemoteFunction"
		Direction  "ClientToServer" | "ServerToClient"
		Purpose    what it is for
		Args       argument schema (Shared.Utilities.Validate) - client->server only
		RateLimit  { Capacity, Refill } token bucket per player (client->server only)
		Response   what the server returns (RemoteFunctions)

	Every RemoteFunction returns { Ok: boolean, Code: ResultCode, Data: any? }.
	Rate-limited or malformed requests are dropped (events) or answered with
	RateLimited / InvalidPayload (functions) and counted as security violations.

	Dependencies: Shared.Utilities.TableUtil
]]

local TableUtil = require(script.Parent.Parent.Utilities.TableUtil)

local ID = { Kind = "string", MaxLength = 40, Pattern = "^[%w_]+$" }
local UID = { Kind = "string", MaxLength = 48, Pattern = "^[%w_%-]+$" }

export type RemoteDefinition = {
	Class: string,
	Direction: string,
	Purpose: string,
	Args: { any }?,
	RateLimit: { Capacity: number, Refill: number }?,
	Response: string?,
}

local Remotes: { [string]: RemoteDefinition } = {
	-- Lobby -------------------------------------------------------------------
	RequestJoinQueue = {
		Class = "RemoteFunction",
		Direction = "ClientToServer",
		Purpose = "Join the lobby matchmaking queue.",
		Args = {},
		RateLimit = { Capacity = 3, Refill = 0.5 },
		Response = "Result",
	},
	RequestLeaveQueue = {
		Class = "RemoteFunction",
		Direction = "ClientToServer",
		Purpose = "Leave the matchmaking queue.",
		Args = {},
		RateLimit = { Capacity = 3, Refill = 0.5 },
		Response = "Result",
	},
	RequestSelectClass = {
		Class = "RemoteFunction",
		Direction = "ClientToServer",
		Purpose = "Equip an owned costume/class (lobby only).",
		Args = { ID },
		RateLimit = { Capacity = 4, Refill = 1 },
		Response = "Result",
	},
	RequestPurchaseClass = {
		Class = "RemoteFunction",
		Direction = "ClientToServer",
		Purpose = "Buy a costume/class with Candies.",
		Args = { ID },
		RateLimit = { Capacity = 3, Refill = 0.5 },
		Response = "Result",
	},
	RequestPurchaseUpgrade = {
		Class = "RemoteFunction",
		Direction = "ClientToServer",
		Purpose = "Buy the next level of a permanent upgrade with Candies.",
		Args = { ID },
		RateLimit = { Capacity = 3, Refill = 0.5 },
		Response = "Result",
	},
	RequestUpdateSettings = {
		Class = "RemoteEvent",
		Direction = "ClientToServer",
		Purpose = "Change a persisted boolean setting.",
		Args = { { Kind = "enum", Values = { "MusicEnabled", "EffectsEnabled" } }, { Kind = "boolean" } },
		RateLimit = { Capacity = 4, Refill = 1 },
	},
	RequestSnapshot = {
		Class = "RemoteFunction",
		Direction = "ClientToServer",
		Purpose = "Fetch profile, shop, chest and extraction state after (re)loading UI.",
		Args = {},
		RateLimit = { Capacity = 3, Refill = 0.5 },
		Response = "Result with Snapshot",
	},

	-- Farming ---------------------------------------------------------------
	RequestBuySeed = {
		Class = "RemoteFunction",
		Direction = "ClientToServer",
		Purpose = "Buy one seed from the current shop stock with Candies.",
		Args = { ID, { Kind = "integer", Min = 0, Max = 1_000_000 } },
		RateLimit = { Capacity = 6, Refill = 3 },
		Response = "Result",
	},
	RequestPlant = {
		Class = "RemoteFunction",
		Direction = "ClientToServer",
		Purpose = "Plant an owned seed in a farm plot slot.",
		Args = { ID, { Kind = "integer", Min = 1, Max = 64 }, ID },
		RateLimit = { Capacity = 6, Refill = 3 },
		Response = "Result",
	},
	RequestHarvest = {
		Class = "RemoteFunction",
		Direction = "ClientToServer",
		Purpose = "Harvest a ripe crop into the Harvest Chest.",
		Args = { UID },
		RateLimit = { Capacity = 8, Refill = 4 },
		Response = "Result",
	},

	-- Defenses / items ----------------------------------------------------------
	RequestPurchaseDefense = {
		Class = "RemoteFunction",
		Direction = "ClientToServer",
		Purpose = "Buy and place a barricade or sentry with Match Coins.",
		Args = { ID, { Kind = "Vector3", MaxMagnitude = 100_000 }, { Kind = "number", Min = -360, Max = 360 } },
		RateLimit = { Capacity = 4, Refill = 2 },
		Response = "Result",
	},
	RequestUpgradeDefense = {
		Class = "RemoteFunction",
		Direction = "ClientToServer",
		Purpose = "Upgrade a placed defense to its next level.",
		Args = { UID },
		RateLimit = { Capacity = 4, Refill = 2 },
		Response = "Result",
	},
	RequestPurchaseItem = {
		Class = "RemoteFunction",
		Direction = "ClientToServer",
		Purpose = "Buy an accessory or use a utility with Match Coins.",
		Args = { ID },
		RateLimit = { Capacity = 4, Refill = 2 },
		Response = "Result",
	},

	-- Combat ------------------------------------------------------------------
	RequestAttack = {
		Class = "RemoteEvent",
		Direction = "ClientToServer",
		Purpose = "Attack intent: where the player aims and a monotonically increasing sequence.",
		Args = { { Kind = "Vector3", MaxMagnitude = 100_000 }, { Kind = "integer", Min = 0, Max = 2 ^ 31 } },
		RateLimit = { Capacity = 5, Refill = 3 },
	},
	RequestUseAbility = {
		Class = "RemoteEvent",
		Direction = "ClientToServer",
		Purpose = "Ability intent: ability id and aim point.",
		Args = { ID, { Kind = "Vector3", MaxMagnitude = 100_000 } },
		RateLimit = { Capacity = 3, Refill = 1 },
	},

	-- Extraction ----------------------------------------------------------------
	RequestEscape = {
		Class = "RemoteFunction",
		Direction = "ClientToServer",
		Purpose = "Choose ESCAPE at the open Escape Door.",
		Args = {},
		RateLimit = { Capacity = 3, Refill = 0.5 },
		Response = "Result",
	},
	RequestContinue = {
		Class = "RemoteFunction",
		Direction = "ClientToServer",
		Purpose = "Choose CONTINUE at the open Escape Door.",
		Args = {},
		RateLimit = { Capacity = 3, Refill = 0.5 },
		Response = "Result",
	},

	-- Server -> client ----------------------------------------------------------
	ProfileUpdated = {
		Class = "RemoteEvent",
		Direction = "ServerToClient",
		Purpose = "Read-only view of the player's persistent profile.",
	},
	ShopUpdated = {
		Class = "RemoteEvent",
		Direction = "ServerToClient",
		Purpose = "Current Seed Shop stock for the player's match.",
	},
	ChestUpdated = {
		Class = "RemoteEvent",
		Direction = "ServerToClient",
		Purpose = "Harvest Chest contents and estimated Candy value.",
	},
	ExtractionUpdated = {
		Class = "RemoteEvent",
		Direction = "ServerToClient",
		Purpose = "Escape Door state: open/closed, deadline, votes, danger preview.",
	},
	MatchEvent = {
		Class = "RemoteEvent",
		Direction = "ServerToClient",
		Purpose = "One-off match events (wave started, boss spawned, match ended...).",
	},
	Notify = {
		Class = "RemoteEvent",
		Direction = "ServerToClient",
		Purpose = "Toast notification { Text, Kind, Duration }.",
	},
	Effect = {
		Class = "RemoteEvent",
		Direction = "ServerToClient",
		Purpose = "Cosmetic effect playback (projectiles, explosions, slashes, damage numbers).",
	},
}

local NetworkConfig = {
	Remotes = Remotes,
	FolderName = "Remotes",
	-- Violations (rate limit / malformed payload) per player inside the window before a
	-- warning is logged; KickOnAbuse also removes the player.
	Security = {
		ViolationWindow = 30,
		ViolationThreshold = 40,
		KickOnAbuse = false,
	},
	-- Effect events farther than this from a client's character are not sent to it.
	EffectCullDistance = 400,
}

return TableUtil.DeepFreeze(NetworkConfig)
