--!strict
-- Global game rules: economy, limits, persistence and anti-abuse tuning.

local GameConfig = {}

GameConfig.StartingCurrency = 300
GameConfig.CurrencyName = "Coins"
GameConfig.MaxCurrency = 1e12

GameConfig.MaxPets = 150 -- pet inventory limit; eggs cannot be hatched while full
GameConfig.MaxItemStack = 99 -- per item id

GameConfig.Income = {
	PlaytimeInterval = 60, -- seconds
	PlaytimeAmount = 15,
}

GameConfig.Data = {
	StoreName = "TameAPet_Profiles_v1",
	KeyPrefix = "Player_",
	-- In Studio, profiles use ProfileStore's mock store unless this is true, so testing
	-- never touches live player data.
	UseLiveDataStoreInStudio = false,
}

GameConfig.Interaction = {
	EggPromptDistance = 12,
	ItemPromptDistance = 10,
	-- Extra studs allowed on top of the prompt distance to absorb latency.
	DistanceTolerance = 8,
}

-- Per-player request budgets: `count` requests per `window` seconds.
GameConfig.RateLimits = {
	RequestSync = { count = 4, window = 5 },
	Purchase = { count = 5, window = 3 },
	EquipCompass = { count = 6, window = 3 },
	EquipPet = { count = 6, window = 3 },
	TamePet = { count = 3, window = 2 },
	SummonMount = { count = 3, window = 3 },
	Dismount = { count = 4, window = 2 },
	MountInput = { count = 40, window = 1 },
	EggClaim = { count = 4, window = 2 },
	ItemPickup = { count = 6, window = 2 },
}

GameConfig.Assets = {
	-- When a configured model is missing from ServerStorage, use a generated placeholder.
	-- Set to false in production to refuse to spawn objects without real art (a warning
	-- is logged and the spawn is skipped).
	AllowPlaceholders = true,
}

GameConfig.Debug = {
	-- Studio-only test kit, applied once to brand-new profiles while running in Studio
	-- (which uses the mock data store by default). Lets you test taming + flight
	-- without grinding for a Legendary egg. Never applies in a live server.
	StudioStarterKit = {
		Enabled = true,
		Pets = { "StormGriffin" },
		Items = { StormCore = 1 },
		Currency = 0,
	},
	-- Log rejected/suspicious remote calls to the server output.
	LogSuspicious = true,
}

return GameConfig
