--!strict
--[[
	RewardService
	Path: ServerScriptService.Server.Services.RewardService

	Every reward is computed here from server state only; no reward is ever granted
	because a client claimed something happened.

	Sources:
		Enemy kill      Match Coins to the killer (+ assists), scaled by wave and accessories
		Wave completion Match Coins to everyone still in the match
		Boss kill       Match Coins to everyone + Cursed Core deposited in the Harvest Chest
		Crop harvest    produce deposited in the Harvest Chest (NOT Candies)
		Recovered crop  a ripe crop stolen by a crow that was shot down returns to the chest
		Extraction      Candies = chest value x conversion x risk bonus (EscapeService)

	CommitMatchStats writes per-match statistics into the profile exactly once per
	session per match (StatsCommitted flag), whichever way the player leaves.

	Dependencies: EconomyConfig, CurrencyId; Registry: CurrencyService,
	              HarvestChestService, DataService, PlayerService, EffectService

	API:
		RewardService:OnEnemyKilled(match, enemy, killer, contributions)
		RewardService:OnWaveCompleted(match)
		RewardService:OnBossKilled(match, boss)
		RewardService:OnCropHarvested(match, session, crop)
		RewardService:OnStolenCropRecovered(match, crop)
		RewardService:CommitMatchStats(session, match, escaped)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local CurrencyId = require(Shared.Constants.CurrencyId)
local EconomyConfig = require(Shared.Config.EconomyConfig)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)

local RewardService = {}

function RewardService:Init() end

local function waveScaled(base: number, wave: number): number
	return base * (1 + EconomyConfig.MatchCoins.KillRewardGrowthPerWave * (math.max(1, wave) - 1))
end

function RewardService:OnEnemyKilled(match: any, enemy: any, killer: Player?, contributions: { [Player]: number })
	local base = waveScaled(enemy.Definition.CoinReward or 0, match.Wave)
	if base <= 0 then
		return
	end
	local coins = EconomyConfig.MatchCoins

	if killer and match.Sessions[killer] then
		local session = match.Sessions[killer]
		local amount = math.floor(base * session:GetCoinMultiplier() + 0.5)
		Services.CurrencyService:Grant(killer, CurrencyId.MatchCoins, amount, "Kill")
		session.MatchStats.Kills += 1
		Services.EffectService:PlayFor(killer, "CoinPopup", { Amount = amount, Position = enemy:GetPosition() })
	end

	local threshold = enemy.MaxHealth * coins.AssistThreshold
	for player, damage in contributions do
		local session = match.Sessions[player]
		if player ~= killer and session and damage >= threshold then
			local amount = math.floor(base * coins.AssistFraction * session:GetCoinMultiplier() + 0.5)
			if amount > 0 then
				Services.CurrencyService:Grant(player, CurrencyId.MatchCoins, amount, "Assist")
			end
		end
	end
end

function RewardService:OnWaveCompleted(match: any)
	local rule = EconomyConfig.MatchCoins.WaveComplete
	local amount = rule.Base + rule.PerWave * match.Wave
	for player, session in match.Sessions do
		Services.CurrencyService:Grant(player, CurrencyId.MatchCoins, amount, "WaveComplete")
		session.MatchStats.WavesSurvived += 1
		session.MatchStats.HighestWave = math.max(session.MatchStats.HighestWave, match.Wave)
	end
	match:Notify(`Wave {match.Wave} cleared! +{amount} coins`, "Success")
end

function RewardService:OnBossKilled(match: any, _boss: any)
	local reward = EconomyConfig.BossChestReward
	local value = reward.BaseValue + reward.ValuePerContinue * match.ContinueLevel
	-- Forced: a boss kill is never lost to a full chest.
	Services.HarvestChestService:Deposit(match, reward.ItemId, reward.DisplayName, reward.Icon, 1, value, true)
	for player, session in match.Sessions do
		Services.CurrencyService:Grant(player, CurrencyId.MatchCoins, EconomyConfig.MatchCoins.BossKill, "BossKill")
		session.MatchStats.BossesDefeated += 1
	end
	match:FireAll("MatchEvent", "BossDefeated", { Wave = match.Wave, ChestValue = value })
	match:Notify(`The Cursed Harvester is defeated! A Cursed Core (+{value}) was added to the chest.`, "Success", 6)
end

function RewardService:OnCropHarvested(match: any, session: any, crop: any)
	local definition = crop.Definition
	Services.HarvestChestService:Deposit(
		match,
		definition.Id,
		definition.DisplayName,
		definition.Icon,
		definition.YieldQuantity,
		definition.UnitValue
	)
	session.MatchStats.Harvested += definition.YieldQuantity
end

function RewardService:OnStolenCropRecovered(match: any, crop: any)
	if not crop:IsRipe() then
		return
	end
	local definition = crop.Definition
	local deposited = Services.HarvestChestService:Deposit(
		match,
		definition.Id,
		definition.DisplayName,
		definition.Icon,
		definition.YieldQuantity,
		definition.UnitValue
	)
	if deposited then
		match:Notify(`Recovered a stolen {definition.DisplayName}!`, "Success")
	else
		match:Notify(`Recovered a stolen {definition.DisplayName}, but the chest is full!`, "Warning")
	end
end

function RewardService:CommitMatchStats(session: any, match: any, escaped: boolean)
	if session.StatsCommitted then
		return
	end
	session.StatsCommitted = true
	local player: Player = session.Player
	local data = Services.DataService
	if not data:IsLoaded(player) then
		return
	end
	local stats = session.MatchStats
	local function add(name: string, amount: number)
		if amount > 0 then
			data:IncrementStatistic(player, name, math.floor(amount))
		end
	end
	add("TotalKills", stats.Kills)
	add("TotalHarvested", stats.Harvested)
	add("TotalWaves", stats.WavesSurvived)
	add("BossesDefeated", stats.BossesDefeated)
	add("MatchesPlayed", 1)
	if escaped then
		add("MatchesEscaped", 1)
	end
	data:RecordHighestWave(player, math.max(stats.HighestWave, match.Wave))
	data:RecordClassMatch(player, session.ClassId, stats.Kills, match.Wave)
	data:RequestSave(player)
end

return RewardService
