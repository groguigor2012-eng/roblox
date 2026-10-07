--!strict
--[[
	DifficultyService
	Path: ServerScriptService.Server.Services.DifficultyService

	The single place where difficulty is calculated. Pure functions of (wave, continue
	level, player count, enemy id) so results are deterministic and unit-tested
	(tests/specs/difficulty_spec.luau). No other module multiplies enemy stats.

		ScaledHealth = BaseHealth
		             * (1 + (WaveHealthMultiplier - 1) * EnemyDifficultyModifier.Health)
		             * PlayerHealthFactor
		             * ContinueFactor(Health)           [BossHealth + boss index for bosses]
		ScaledSpeed  = BaseSpeed
		             * (1 + (WaveSpeedMultiplier - 1) * EnemyDifficultyModifier.Speed)
		             * ContinueFactor(Speed)
		ScaledDamage = Damage * WaveDamageMultiplier * ContinueFactor(Damage)

	Dependencies: DifficultyConfig, WaveConfig, EnemyConfig

	API:
		DifficultyService:GetWaveMultiplier(curveName, wave) -> number
		DifficultyService:GetContinueFactor(stat, continueLevel) -> number
		DifficultyService:GetEnemyStats(enemyId, context) -> { MaxHealth, Speed, Damage, CropDamage, StructureDamage, DamageFactor }
		DifficultyService:GetEnemyCount(wave, context) -> number
		DifficultyService:GetSpawnInterval(wave, continueLevel) -> number
		DifficultyService:GetBurstSize(wave) -> number
		DifficultyService:GetSpecialShare(wave, continueLevel) -> number
		DifficultyService:GetSpecialWeightMultiplier(continueLevel) -> number
		DifficultyService:IsBossWave(wave) -> boolean
		DifficultyService:GetBossIndex(wave) -> number         -- 1 for wave 10, 2 for wave 20 ...
		DifficultyService:GetDangerMultiplier(continueLevel) -> number   -- HUD "danger" readout

	context = { Wave: number, ContinueLevel: number, PlayerCount: number }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local DifficultyConfig = require(Shared.Config.DifficultyConfig)
local EnemyConfig = require(Shared.Config.EnemyConfig)
local WaveConfig = require(Shared.Config.WaveConfig)

export type Context = { Wave: number, ContinueLevel: number, PlayerCount: number }
export type EnemyStats = {
	MaxHealth: number,
	Speed: number,
	Damage: number,
	CropDamage: number,
	StructureDamage: number,
	DamageFactor: number,
}

local DifficultyService = {}

function DifficultyService:Init() end

function DifficultyService:GetWaveMultiplier(curveName: string, wave: number): number
	local curve = DifficultyConfig.Curves[curveName]
	assert(curve, `[DifficultyService] unknown curve {curveName}`)
	local w = math.max(1, math.floor(wave))
	local preCapWaves = math.min(w, curve.SoftCapWave) - 1
	local postCapWaves = math.max(0, w - curve.SoftCapWave)
	local multiplier = curve.Growth ^ (curve.Exponent * preCapWaves) * curve.PostSoftCapGrowth ^ postCapWaves
	return math.min(curve.MaxMultiplier, multiplier)
end

function DifficultyService:GetContinueFactor(stat: string, continueLevel: number): number
	local continue = DifficultyConfig.Continue
	local weight = continue.Weights[stat]
	assert(weight ~= nil, `[DifficultyService] unknown continue stat {stat}`)
	local level = math.clamp(math.floor(continueLevel), 0, continue.MaxLevel)
	return 1 + (continue.Multiplier ^ level - 1) * weight
end

function DifficultyService:IsBossWave(wave: number): boolean
	return wave > 0 and wave % WaveConfig.BossEvery == 0
end

function DifficultyService:GetBossIndex(wave: number): number
	return math.max(1, wave // WaveConfig.BossEvery)
end

function DifficultyService:GetEnemyStats(enemyId: string, context: Context): EnemyStats
	local definition = EnemyConfig.Get(enemyId)
	assert(definition, `[DifficultyService] unknown enemy {enemyId}`)
	local scaling = definition.Scaling or { Health = 1, Speed = 1 }

	local waveHealth = self:GetWaveMultiplier("Health", context.Wave)
	local waveSpeed = self:GetWaveMultiplier("Speed", context.Wave)
	local waveDamage = self:GetWaveMultiplier("Damage", context.Wave)

	local healthFactor = 1 + (waveHealth - 1) * scaling.Health
	local speedFactor = 1 + (waveSpeed - 1) * scaling.Speed
	local playerFactor = 1 + DifficultyConfig.Players.HealthPerExtraPlayer * math.max(0, context.PlayerCount - 1)

	local continueHealth = if definition.IsBoss
		then self:GetContinueFactor("BossHealth", context.ContinueLevel)
		else self:GetContinueFactor("Health", context.ContinueLevel)
	local bossFactor = if definition.IsBoss
		then 1 + DifficultyConfig.Boss.HealthPerBossIndex * (self:GetBossIndex(context.Wave) - 1)
		else 1
	local continueSpeed = self:GetContinueFactor("Speed", context.ContinueLevel)
	local continueDamage = self:GetContinueFactor("Damage", context.ContinueLevel)
	local damageFactor = waveDamage * continueDamage

	return {
		MaxHealth = math.floor(definition.BaseHealth * healthFactor * playerFactor * continueHealth * bossFactor + 0.5),
		Speed = definition.BaseSpeed * speedFactor * continueSpeed,
		Damage = (definition.Damage or 0) * damageFactor,
		CropDamage = (definition.CropDamage or 0) * damageFactor,
		StructureDamage = (definition.StructureDamage or 0) * damageFactor,
		-- For damage values that live outside the common fields (landing shockwaves, potions).
		DamageFactor = damageFactor,
	}
end

function DifficultyService:GetEnemyCount(wave: number, context: Context): number
	local rule = WaveConfig.EnemyCount
	local w = math.max(1, wave)
	local base = (rule.Base + rule.PerWave * (w - 1)) * rule.Growth ^ (w - 1)
	local playerFactor = 1 + DifficultyConfig.Players.DensityPerExtraPlayer * math.max(0, context.PlayerCount - 1)
	local continueFactor = self:GetContinueFactor("Density", context.ContinueLevel)
	local count = math.floor(base * playerFactor * continueFactor + 0.5)
	if self:IsBossWave(w) then
		count = math.floor(count * WaveConfig.BossEscortMultiplier + 0.5)
	end
	return math.clamp(count, 1, rule.Max)
end

function DifficultyService:GetSpawnInterval(wave: number, continueLevel: number): number
	local rule = WaveConfig.SpawnInterval
	local interval = rule.Base + rule.PerWave * (math.max(1, wave) - 1)
	interval /= self:GetContinueFactor("SpawnPressure", continueLevel)
	return math.max(rule.Min, interval)
end

function DifficultyService:GetBurstSize(wave: number): number
	local rule = WaveConfig.BurstSize
	return math.min(rule.Max, rule.Base + (math.max(1, wave) - 1) // rule.PerWaves)
end

function DifficultyService:GetSpecialShare(wave: number, continueLevel: number): number
	local share = WaveConfig.SpecialShareBase + WaveConfig.SpecialSharePerWave * (math.max(1, wave) - 1)
	share += DifficultyConfig.Continue.SpecialSharePerLevel * continueLevel
	return math.min(WaveConfig.SpecialShareMax + DifficultyConfig.Continue.SpecialSharePerLevel * continueLevel, share)
end

function DifficultyService:GetSpecialWeightMultiplier(continueLevel: number): number
	return 1 + DifficultyConfig.Continue.SpecialChancePerLevel * continueLevel
end

function DifficultyService:GetDangerMultiplier(continueLevel: number): number
	return self:GetContinueFactor("Health", continueLevel)
end

return DifficultyService
