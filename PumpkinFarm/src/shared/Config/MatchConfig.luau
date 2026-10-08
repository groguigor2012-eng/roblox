--!strict
--[[
	MatchConfig
	Path: ReplicatedStorage.Shared.Config.MatchConfig

	Match lifecycle timing, lobby/queue rules, arena layout and interaction ranges.
	Read by LobbyService, MatchService, Match, MapBuilder, EscapeService and the
	interaction validators in CropService / DefenseService.

	Dependencies: Shared.Utilities.TableUtil
]]

local TableUtil = require(script.Parent.Parent.Utilities.TableUtil)

local MatchConfig = {
	MaxPlayersPerMatch = 4,
	-- Seconds the lobby queue waits for more players once someone joins it.
	QueueCountdown = 8,
	-- Simultaneous matches (arenas) one server can host.
	MaxConcurrentMatches = 4,
	-- Match state machine update rate (Hz).
	UpdateRate = 10,

	Phases = {
		WaitingTimeout = 15,
		Starting = 5,
		FirstIntermission = 40,
		Intermission = 25,
		PreparingWave = 4,
		WaveComplete = 4,
		ExtractionDecision = 30,
		ContinuePreparation = 30,
		MatchEnding = 8,
	},

	-- The Escape Door opens after every Nth completed wave (boss waves are multiples of 10).
	ExtractionEveryWaves = 5,

	-- What a Continue restores before the preparation countdown.
	ContinueRecovery = {
		HealPlayers = true,
		RepairDefensesFraction = 0.35,
		CoreHealFraction = 0.25,
	},

	Lobby = {
		Origin = Vector3.new(0, 0, 0),
		Size = Vector3.new(140, 4, 140),
		RespawnDelay = 3,
	},

	Arena = {
		Origin = Vector3.new(1200, 0, 0),
		Spacing = 1200,
		Size = 380,
		WallHeight = 80,
		EnemySpawnRadius = 160,
		EnemySpawnPoints = 8,
		PlayerSpawnRadius = 14,
		RockCount = 14,
		DecorPumpkinCount = 22,
		AlienTreeCount = 18,
		-- Lowest Y (relative to the floor) before a player/enemy is considered fallen.
		KillPlaneDepth = 60,
	},

	Farm = {
		FenceRadius = 44,
		FenceHeight = 5,
		GateCount = 4,
		GateWidth = 16,
		PlotCount = 6,
		PlotRingRadius = 26,
		PlotSize = Vector3.new(14, 1, 10),
		SlotColumns = 3,
		SlotRows = 2,
		-- Each player owns this many plots (assigned in join order by UserId); the rest
		-- are shared. Only the owner may plant on an owned plot; anyone may harvest
		-- (the chest is the team's). A leaving player's plots become shared.
		PlotsPerPlayer = 1,
	},

	Core = {
		DisplayName = "The Great Pumpkin",
		MaxHealth = 2500,
		Radius = 6,
		FoundationRadius = 9,
	},

	Chest = {
		Offset = Vector3.new(0, 0, 13),
	},

	Door = {
		Offset = Vector3.new(0, 0, -36),
	},

	Interaction = {
		PlantRange = 14,
		-- Minimum seconds between two successful plantings by the same player.
		PlantCooldown = 0.5,
		HarvestRange = 14,
		DoorRange = 18,
	},

	-- Seed purchases are only accepted in these states.
	SeedShopOpenStates = { "Starting", "Intermission", "WaveComplete", "ContinuePreparation" },
}

return TableUtil.DeepFreeze(MatchConfig)
