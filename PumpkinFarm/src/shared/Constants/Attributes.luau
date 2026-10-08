--!strict
--[[
	Attributes
	Path: ReplicatedStorage.Shared.Constants.Attributes

	Names of every Instance attribute the server writes for clients to read. Using
	constants avoids typo bugs between the server writer and the client reader.

	Written on Player (by CurrencyService / PlayerService / StatusEffectService):
		Candies, MatchCoins, ClassId, MatchId, LifeState, ProfileStatus, Effects, Queued,
		QueueEndsAt, QueueSize
	Written on the match folder workspace.Matches.Match_<id> (by Match / WaveService / CropService / EscapeService):
		MatchId, State, Wave, IsBossWave, EnemiesRemaining, PhaseEndsAt, ContinueLevel,
		DifficultyMultiplier, CoreHealth, CoreMaxHealth, ChestValue, Objective,
		BossActive, BossName, BossHealth, BossMaxHealth, BossAuraRadius, BossEnraged
	Written on crop models (by Crop): CropUid, CropId, Stage, Growth, Health, MaxHealth, Ripe, MatchId
	Written on enemy models (by EnemyBase): EnemyUid, EnemyId, Health, MaxHealth, Underground
	Written on defense models (by Barricade / Sentry): DefenseUid, DefenseId, Health, MaxHealth, Level
	Written on plot slot parts (by MapBuilder): PlotId, SlotIndex
	Written on plot and slot parts (by CropService): PlotOwnerId (UserId, 0 = shared), PlotOwnerName
	Written on map parts (by MapBuilder, read by UndergroundRouter): Diggable, NoDig
]]

return table.freeze({
	-- Player
	Candies = "Candies",
	MatchCoins = "MatchCoins",
	ClassId = "ClassId",
	MatchId = "MatchId",
	LifeState = "LifeState",
	ProfileStatus = "ProfileStatus",
	Effects = "Effects",
	Queued = "Queued",
	QueueEndsAt = "QueueEndsAt",
	QueueSize = "QueueSize",

	-- Match folder
	State = "State",
	Wave = "Wave",
	IsBossWave = "IsBossWave",
	EnemiesRemaining = "EnemiesRemaining",
	PhaseEndsAt = "PhaseEndsAt",
	ContinueLevel = "ContinueLevel",
	DifficultyMultiplier = "DifficultyMultiplier",
	CoreHealth = "CoreHealth",
	CoreMaxHealth = "CoreMaxHealth",
	ChestValue = "ChestValue",
	Objective = "Objective",
	BossActive = "BossActive",
	BossName = "BossName",
	BossHealth = "BossHealth",
	BossMaxHealth = "BossMaxHealth",
	BossAuraRadius = "BossAuraRadius",
	BossEnraged = "BossEnraged",

	-- Entities
	CropUid = "CropUid",
	CropId = "CropId",
	Stage = "Stage",
	Growth = "Growth",
	Ripe = "Ripe",
	Health = "Health",
	MaxHealth = "MaxHealth",
	EnemyUid = "EnemyUid",
	EnemyId = "EnemyId",
	Underground = "Underground",
	DefenseUid = "DefenseUid",
	DefenseId = "DefenseId",
	Level = "Level",
	PlotId = "PlotId",
	SlotIndex = "SlotIndex",
	PlotOwnerId = "PlotOwnerId",
	PlotOwnerName = "PlotOwnerName",
	Diggable = "Diggable",
	NoDig = "NoDig",
	WeaponId = "WeaponId",
})
