--!strict
-- Shared type definitions: persisted data, movement states and every remote
-- payload. Pure types; this module returns an empty table.

export type CurrencyType = "Shards" | "PowerOrbs"

export type PlayerData = {
	SchemaVersion: number,
	Shards: number,
	PowerOrbs: number,
	-- Set of stable collectible ids: { [id] = true }.
	CollectedCollectibles: { [string]: boolean },
}

-- Client movement state. Grounded/Rising/Falling are derived from physics;
-- the rest are set while an ability runs. "Landing" is the ground-pound
-- recovery; "SpinFloating" is the spin + float after a double jump.
export type MovementState =
	"Grounded"
	| "Rising"
	| "Falling"
	| "Dashing"
	| "GroundPounding"
	| "Landing"
	| "WallJumping"
	| "SpinFloating"
	| "Dead"

-- Actions the client reports through MovementAction.
export type MovementAction = "DoubleJump" | "Dash" | "GroundPoundStart" | "WallJump"

export type CollectMode = "PerPlayer" | "Shared"

-- Server -> client reply to a CollectRequest.
export type CollectResult = {
	Success: boolean,
	-- The requested instance (nil on the client if it has streamed out).
	Instance: Instance?,
	-- Stable id when the item has one.
	CollectibleId: string?,
	CurrencyType: CurrencyType?,
	Amount: number?,
	NewTotal: number?,
	-- Failure reason ("AlreadyCollected", "TooFar", ...).
	Reason: string?,
}

-- Server -> client: stable ids this player has already collected.
export type CollectionState = {
	CollectedIds: { string },
}

export type BrokenPartInfo = {
	CFrame: CFrame,
	Size: Vector3,
	Color: Color3,
	Material: Enum.Material,
}

-- Server -> clients: a validated ground-pound impact.
export type ImpactEffect = {
	Position: Vector3,
	Radius: number,
	SourceUserId: number,
	Broken: { BrokenPartInfo },
}

export type Remotes = {
	CollectRequest: RemoteEvent,
	CollectResult: RemoteEvent,
	CollectionState: RemoteEvent,
	MovementAction: RemoteEvent,
	GroundPoundImpact: RemoteEvent,
	ImpactEffect: RemoteEvent,
}

return {}
