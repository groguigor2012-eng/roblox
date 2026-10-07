--!strict
--[[
	WaveComposer
	Path: ServerScriptService.Server.Systems.WaveComposer

	Turns (wave number, match context, seeded Random) into a deterministic spawn plan.
	Pure function: no Instances, no services beyond the injected difficulty calculator,
	so it is unit-tested headlessly (tests/specs/wave_spec.luau).

	Algorithm:
		1. total count from DifficultyService (wave curve, players, Continue density)
		2. special share of the wave (grows per wave and per Continue level)
		3. special slots are filled by weighted picks among unlocked archetypes, with
		   weights boosted by the Continue special-chance multiplier and capped by each
		   archetype's MaxShare / MaxPerWave
		4. remaining slots are grunts
		5. order: frontline shuffled; backline archetypes (Witch) are only placed after
		   the FrontlineLead fraction so they arrive behind the horde
		6. boss waves put the Cursed Harvester first

	Dependencies: WaveConfig, WeightedRandom, TableUtil

	API:
		WaveComposer.Compose(wave, context, rng, difficulty) -> Plan
			Plan = { Wave, IsBoss, Entries: { enemyId }, SpawnInterval, BurstSize, Counts }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local TableUtil = require(Shared.Utilities.TableUtil)
local WaveConfig = require(Shared.Config.WaveConfig)
local WeightedRandom = require(Shared.Utilities.WeightedRandom)

export type Plan = {
	Wave: number,
	IsBoss: boolean,
	Entries: { string },
	SpawnInterval: number,
	BurstSize: number,
	Counts: { [string]: number },
}

local WaveComposer = {}

function WaveComposer.Compose(wave: number, context: any, rng: Random, difficulty: any): Plan
	local total = difficulty:GetEnemyCount(wave, context)
	local level = context.ContinueLevel
	local specialShare = difficulty:GetSpecialShare(wave, level)
	local specialMultiplier = difficulty:GetSpecialWeightMultiplier(level)
	local specialSlots = math.floor(total * specialShare + 0.5)

	-- Stable archetype order keeps the plan deterministic for a given seed.
	local archetypeIds = TableUtil.Keys(WaveConfig.Archetypes)
	local caps: { [string]: number } = {}
	local unlocked: { string } = {}
	for _, enemyId in archetypeIds do
		local rule = WaveConfig.Archetypes[enemyId]
		if wave >= rule.UnlockWave then
			local cap = math.max(1, math.floor(total * rule.MaxShare))
			if rule.MaxPerWave then
				cap = math.min(cap, rule.MaxPerWave)
			end
			caps[enemyId] = cap
			table.insert(unlocked, enemyId)
		end
	end

	local counts: { [string]: number } = {}
	local frontline: { string } = {}
	local backline: { string } = {}
	for _ = 1, specialSlots do
		local available = {}
		for _, enemyId in unlocked do
			if (counts[enemyId] or 0) < caps[enemyId] then
				table.insert(available, enemyId)
			end
		end
		local choice = WeightedRandom.Pick(available, function(enemyId: string): number
			local rule = WaveConfig.Archetypes[enemyId]
			local weight = rule.Weight + rule.WeightPerWave * (wave - rule.UnlockWave)
			if rule.Special then
				weight *= specialMultiplier
			end
			return weight
		end, rng)
		if choice == nil then
			break
		end
		counts[choice] = (counts[choice] or 0) + 1
		if WaveConfig.Archetypes[choice].Backline then
			table.insert(backline, choice)
		else
			table.insert(frontline, choice)
		end
	end

	local placed = #frontline + #backline
	for _ = placed + 1, total do
		table.insert(frontline, WaveConfig.GruntEnemyId)
	end
	counts[WaveConfig.GruntEnemyId] = total - placed

	TableUtil.Shuffle(frontline, rng)
	local entries = frontline
	local lead = math.max(1, math.floor(#entries * WaveConfig.FrontlineLead))
	for _, enemyId in backline do
		local position = rng:NextInteger(math.min(lead + 1, #entries + 1), #entries + 1)
		table.insert(entries, position, enemyId)
	end

	local isBoss = difficulty:IsBossWave(wave)
	if isBoss then
		table.insert(entries, 1, WaveConfig.BossEnemyId)
		counts[WaveConfig.BossEnemyId] = 1
	end

	return {
		Wave = wave,
		IsBoss = isBoss,
		Entries = entries,
		SpawnInterval = difficulty:GetSpawnInterval(wave, level),
		BurstSize = difficulty:GetBurstSize(wave),
		Counts = counts,
	}
end

return WaveComposer
