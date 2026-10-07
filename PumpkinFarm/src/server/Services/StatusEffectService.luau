--!strict
--[[
	StatusEffectService
	Path: ServerScriptService.Server.Services.StatusEffectService

	Server-authoritative timed effects (Stunned, Slowed, Hexed, Chilled, BossAura,
	SpawnProtection) for players and enemies. Targets are objects implementing:
		Kind ("Player" | anything else = enemy), IsAlive(), OnStatusEffectsChanged()
	PlayerSession and EnemyBase both implement it, so movement/attack code simply asks
	this service for multipliers.

	Stacking rules come from StatusEffectConfig (Refresh / Ignore / Extend) and an
	optional post-expiry immunity window, which is what prevents stun-locking.
	Player effects are mirrored to the Player "Effects" attribute as JSON
	{ [effectId] = expiresAt (server time) } for the HUD.

	One sweep loop (StatusEffectConfig.TickInterval) expires effects for all targets.

	Dependencies: StatusEffectConfig, Attributes, Clock

	API:
		StatusEffectService:Apply(target, effectId, options?) -> boolean
			options = { Duration: number?, Source: any? }
		StatusEffectService:Remove(target, effectId)
		StatusEffectService:Has(target, effectId) -> boolean
		StatusEffectService:ClearTarget(target)
		StatusEffectService:GetSpeedMultiplier(target) -> number
		StatusEffectService:GetAttackSpeedMultiplier(target) -> number
		StatusEffectService:GetDamageTakenMultiplier(target) -> number
		StatusEffectService:BlocksAttacks(target) -> boolean
		StatusEffectService:BlocksJump(target) -> boolean
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local Clock = require(Shared.Utilities.Clock)
local StatusEffectConfig = require(Shared.Config.StatusEffectConfig)

type ActiveEffect = { ExpiresAt: number, Source: any }

local StatusEffectService = {}

local active: { [any]: { [string]: ActiveEffect } } = {}
local immunity: { [any]: { [string]: number } } = {}

local function targetKind(target: any): string
	return if target.Kind == "Player" then "Player" else "Enemy"
end

local function publish(target: any)
	local ok, err = pcall(function()
		target:OnStatusEffectsChanged()
	end)
	if not ok then
		warn(`[StatusEffectService] OnStatusEffectsChanged failed: {err}`)
	end
	if target.Kind == "Player" and target.Player then
		local effects = active[target]
		local view = {}
		if effects then
			for effectId, effect in effects do
				view[effectId] = effect.ExpiresAt
			end
		end
		target.Player:SetAttribute(Attributes.Effects, if next(view) then HttpService:JSONEncode(view) else nil)
	end
end

function StatusEffectService:Init() end

function StatusEffectService:Start()
	task.spawn(function()
		while true do
			task.wait(StatusEffectConfig.TickInterval)
			local now = Clock.Now()
			for target, effects in active do
				local changed = false
				local alive = target.IsAlive and target:IsAlive()
				for effectId, effect in effects do
					if not alive or effect.ExpiresAt <= now then
						effects[effectId] = nil
						changed = true
						local definition = StatusEffectConfig.Get(effectId)
						if alive and definition and definition.ImmunityDuration then
							immunity[target] = immunity[target] or {}
							immunity[target][effectId] = now + definition.ImmunityDuration
						end
					end
				end
				if next(effects) == nil then
					active[target] = nil
				end
				if changed and alive then
					publish(target)
				end
			end
			for target, entries in immunity do
				for effectId, untilTime in entries do
					if untilTime <= now then
						entries[effectId] = nil
					end
				end
				if next(entries) == nil then
					immunity[target] = nil
				end
			end
		end
	end)
end

function StatusEffectService:Apply(target: any, effectId: string, options: { Duration: number?, Source: any? }?): boolean
	local definition = StatusEffectConfig.Get(effectId)
	if definition == nil then
		warn(`[StatusEffectService] unknown effect {effectId}`)
		return false
	end
	if not (definition.Targets :: any)[targetKind(target)] then
		return false
	end
	if not target:IsAlive() then
		return false
	end

	local now = Clock.Now()
	local immuneUntil = immunity[target] and immunity[target][effectId]
	if immuneUntil and immuneUntil > now then
		return false
	end

	local duration = (options and options.Duration) or definition.Duration
	if duration <= 0 then
		return false
	end
	local effects = active[target]
	if effects == nil then
		effects = {}
		active[target] = effects
	end

	local existing = effects[effectId]
	if existing then
		if definition.Stacking == "Ignore" then
			return false
		elseif definition.Stacking == "Extend" then
			local cap = now + (definition.MaxDuration or duration)
			existing.ExpiresAt = math.min(cap, existing.ExpiresAt + duration)
		else
			existing.ExpiresAt = math.max(existing.ExpiresAt, now + duration)
		end
		existing.Source = options and options.Source
	else
		effects[effectId] = { ExpiresAt = now + duration, Source = options and options.Source }
	end
	publish(target)
	return true
end

function StatusEffectService:Remove(target: any, effectId: string)
	local effects = active[target]
	if effects and effects[effectId] then
		effects[effectId] = nil
		if next(effects) == nil then
			active[target] = nil
		end
		publish(target)
	end
end

function StatusEffectService:Has(target: any, effectId: string): boolean
	local effects = active[target]
	local effect = effects and effects[effectId]
	return effect ~= nil and effect.ExpiresAt > Clock.Now()
end

function StatusEffectService:ClearTarget(target: any)
	local had = active[target] ~= nil
	active[target] = nil
	immunity[target] = nil
	if had then
		publish(target)
	end
end

local function product(target: any, field: string): number
	local effects = active[target]
	if effects == nil then
		return 1
	end
	local now = Clock.Now()
	local result = 1
	for effectId, effect in effects do
		if effect.ExpiresAt > now then
			local definition = StatusEffectConfig.Get(effectId)
			local value = definition and (definition :: any)[field]
			if value ~= nil then
				result *= value
			end
		end
	end
	return result
end

local function anyFlag(target: any, field: string): boolean
	local effects = active[target]
	if effects == nil then
		return false
	end
	local now = Clock.Now()
	for effectId, effect in effects do
		local definition = StatusEffectConfig.Get(effectId)
		if effect.ExpiresAt > now and definition and (definition :: any)[field] then
			return true
		end
	end
	return false
end

function StatusEffectService:GetSpeedMultiplier(target: any): number
	return product(target, "SpeedMultiplier")
end

function StatusEffectService:GetAttackSpeedMultiplier(target: any): number
	return product(target, "AttackSpeedMultiplier")
end

function StatusEffectService:GetDamageTakenMultiplier(target: any): number
	return product(target, "DamageTakenMultiplier")
end

function StatusEffectService:BlocksAttacks(target: any): boolean
	return anyFlag(target, "BlocksAttacks")
end

function StatusEffectService:BlocksJump(target: any): boolean
	return anyFlag(target, "BlocksJump")
end

return StatusEffectService
