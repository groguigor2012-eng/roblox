--!strict
-- Every remote the game uses. The server creates any that are missing (so the game also
-- works without Rojo); the client only ever looks remotes up by these names.
-- Payload contracts are documented in docs/ARCHITECTURE.md.

export type RemoteSpec = { name: string, className: "RemoteEvent" | "RemoteFunction" | "UnreliableRemoteEvent" }

local RemoteNames = {}

RemoteNames.FolderName = "Remotes"

RemoteNames.List = {
	-- Client -> server requests (RemoteFunction returns a Result table)
	{ name = "RequestSync", className = "RemoteFunction" },
	{ name = "Purchase", className = "RemoteFunction" },
	{ name = "EquipCompass", className = "RemoteFunction" },
	{ name = "EquipPet", className = "RemoteFunction" },
	{ name = "TamePet", className = "RemoteFunction" },
	{ name = "SummonMount", className = "RemoteFunction" },
	{ name = "Dismount", className = "RemoteFunction" },
	-- Client -> server stream
	{ name = "MountInput", className = "UnreliableRemoteEvent" },
	-- Server -> client pushes
	{ name = "ProfileSync", className = "RemoteEvent" },
	{ name = "CompassTarget", className = "RemoteEvent" },
	{ name = "HatchResult", className = "RemoteEvent" },
	{ name = "MountState", className = "RemoteEvent" },
	{ name = "Notify", className = "RemoteEvent" },
} :: { RemoteSpec }

-- Result codes returned by request remotes.
RemoteNames.Codes = {
	Ok = "Ok",
	BadRequest = "BadRequest",
	NotReady = "NotReady",
	RateLimited = "RateLimited",
	Busy = "Busy",
	ServerError = "ServerError",
	NotOwned = "NotOwned",
	NotFound = "NotFound",
	InsufficientFunds = "InsufficientFunds",
	AlreadyOwned = "AlreadyOwned",
	AlreadyTamed = "AlreadyTamed",
	NotTamed = "NotTamed",
	MissingItem = "MissingItem",
	Locked = "Locked",
	Maxed = "Maxed",
	InventoryFull = "InventoryFull",
	NoCharacter = "NoCharacter",
	Cooldown = "Cooldown",
	ConfigError = "ConfigError",
}

return RemoteNames
