--!strict
--[[
	Types
	Path: ReplicatedStorage.Shared.Types.Types

	Shared data shapes that cross module or network boundaries. Server modules use them
	to type their public APIs; client controllers use them to type remote payloads.
]]

export type Result = {
	Ok: boolean,
	Code: string,
	Data: any?,
}

export type ProfileData = {
	Candies: number,
	UnlockedCostumes: { [string]: boolean },
	EquippedCostume: string?,
	Seeds: { [string]: number },
	ClassStats: { [string]: { MatchesPlayed: number, Kills: number, HighestWave: number } },
	PermanentUpgrades: { [string]: number },
	Statistics: {
		TotalWaves: number,
		TotalKills: number,
		TotalHarvested: number,
		BossesDefeated: number,
		MatchesPlayed: number,
		MatchesEscaped: number,
		HighestWave: number,
	},
	Settings: {
		MusicEnabled: boolean,
		EffectsEnabled: boolean,
	},
	Version: number,
}

-- Read-only profile view sent to the owning client (ProfileUpdated).
export type ProfileView = {
	Candies: number,
	UnlockedCostumes: { [string]: boolean },
	EquippedCostume: string,
	Seeds: { [string]: number },
	PermanentUpgrades: { [string]: number },
	Statistics: { [string]: number },
	Settings: { [string]: boolean },
	IsTemporary: boolean,
}

export type ShopStockEntry = {
	SeedId: string,
	Quantity: number,
	Price: number,
	PerPlayerLimit: number?,
	Purchased: number?, -- per-player count, filled in for the receiving client
}

export type ShopSnapshot = {
	Version: number,
	Open: boolean,
	Entries: { ShopStockEntry },
	RestockedAt: number,
}

export type ChestEntry = {
	ItemId: string,
	DisplayName: string,
	Icon: string,
	Quantity: number,
	UnitValue: number,
	Value: number,
}

export type ChestSnapshot = {
	Entries: { ChestEntry },
	TotalValue: number,
	EstimatedCandies: number,
	RiskBonus: number,
	Locked: boolean,
}

export type ExtractionSnapshot = {
	Open: boolean,
	DeadlineAt: number,
	Decisions: { [string]: string }, -- [tostring(userId)] = "Escape" | "Continue"
	YourDecision: string?,
	EstimatedCandies: number,
	NextContinueLevel: number,
	NextHealthMultiplier: number,
	DoorPosition: Vector3?,
}

export type Snapshot = {
	Profile: ProfileView?,
	Shop: ShopSnapshot?,
	Chest: ChestSnapshot?,
	Extraction: ExtractionSnapshot?,
}

export type EffectParams = { [string]: any }

return table.freeze({})
