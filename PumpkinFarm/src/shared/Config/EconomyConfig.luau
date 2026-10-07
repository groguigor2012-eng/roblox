--!strict
--[[
	EconomyConfig
	Path: ReplicatedStorage.Shared.Config.EconomyConfig

	Currency flow tuning for both currencies, consumed by RewardService, MatchCoinService,
	CandyService, EscapeService and the lobby upgrade shop.

	Dependencies: Shared.Utilities.TableUtil
]]

local TableUtil = require(script.Parent.Parent.Utilities.TableUtil)

local EconomyConfig = {
	MatchCoins = {
		-- Granted to every player when a match starts (plus Deep Pockets upgrade levels).
		Starting = 150,
		Max = 1_000_000,
		-- Kill rewards grow by this fraction per wave after the first.
		KillRewardGrowthPerWave = 0.05,
		-- Players who dealt at least AssistThreshold of an enemy's max health (and did
		-- not land the killing blow) receive AssistFraction of the reward.
		AssistThreshold = 0.1,
		AssistFraction = 0.4,
		WaveComplete = { Base = 40, PerWave = 8 },
		BossKill = 400,
	},

	Candies = {
		Max = 1_000_000_000,
		-- Harvest Chest value converts to Candies at this rate on extraction.
		ConversionRate = 1,
		-- Escaping after Continues pays more: payout * (1 + RiskBonusPerContinue * level).
		RiskBonusPerContinue = 0.25,
	},

	-- Defeating the Cursed Harvester deposits a Cursed Core into the Harvest Chest.
	BossChestReward = {
		ItemId = "CursedCore",
		DisplayName = "Cursed Core",
		Icon = "💀",
		BaseValue = 500,
		ValuePerContinue = 250,
	},

	-- Guarantees a broke player can always farm: on match start, a player with fewer
	-- Candies than the cheapest seed and no seeds receives this grant (persisted).
	SoftLockGrant = {
		SeedId = "NeonStarFruit",
		Quantity = 2,
	},

	PermanentUpgrades = {
		DeepPockets = {
			Id = "DeepPockets",
			DisplayName = "Deep Pockets",
			Description = "+25 starting Match Coins per level.",
			Costs = { 200, 400, 700, 1100, 1600 },
			StartingCoinsPerLevel = 25,
			Icon = "👛",
			SortOrder = 1,
		},
		GreenThumb = {
			Id = "GreenThumb",
			DisplayName = "Green Thumb",
			Description = "Crops you plant grow 8% faster per level.",
			Costs = { 300, 700, 1400 },
			GrowthSpeedPerLevel = 0.08,
			Icon = "🌱",
			SortOrder = 2,
		},
	},
}

return TableUtil.DeepFreeze(EconomyConfig)
