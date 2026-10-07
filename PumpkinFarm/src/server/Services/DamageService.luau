--!strict
--[[
	DamageService
	Path: ServerScriptService.Server.Services.DamageService

	The single path through which any damage is applied. Damage amounts are always
	computed on the server from configs; clients never supply them.

	DamageSource fields (all optional except Kind):
		Kind               "Weapon" | "Ability" | "Sentry" | "Enemy" | "Crop" | "Environment"
		Player             attacking player (kill credit / assists)
		Enemy              attacking enemy object (thorns, crop vulnerability)
		Id                 weapon / ability / defense id
		MovementType       attacker movement type ("Ground" | "Air" | "Underground")
		IsBoss             attacker is a boss
		CanHitUnderground  magic that reaches buried moles

	Dependencies: Registry: EnemyService, EffectService, StatusEffectService

	API:
		DamageService:DamageEnemy(enemy, amount, source) -> number
		DamageService:DamagePlayer(session, amount, source) -> number
		DamageService:DamageTarget(target, amount, source) -> number
		DamageService:DamageEnemiesInRadius(match, center, radius, baseDamage, source, options?) -> { enemy }
			options = { MinFalloff, IncludeUnderground, IncludeAir, MaxTargets, Effect,
			            EffectDuration, Knockback, ConeDirection, ConeAngle }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MathUtil = require(ReplicatedStorage.Shared.Utilities.MathUtil)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)

local DamageService = {}

function DamageService:Init() end

function DamageService:DamageEnemy(enemy: any, amount: number, source: any): number
	if enemy == nil or not enemy:IsAlive() or amount <= 0 then
		return 0
	end
	local dealt = enemy:TakeDamage(amount, source)
	if dealt > 0 and source.Player then
		Services.EffectService:PlayFor(source.Player, "DamageNumber", {
			Position = enemy:GetPosition(),
			Amount = math.floor(dealt + 0.5),
		})
	end
	return dealt
end

function DamageService:DamagePlayer(session: any, amount: number, source: any): number
	if session == nil or not session:IsAlive() or amount <= 0 then
		return 0
	end
	local dealt = session:TakeDamage(amount, source)
	if dealt > 0 then
		Services.EffectService:PlayFor(session.Player, "Hurt", { Amount = math.floor(dealt + 0.5) })
	end
	return dealt
end

function DamageService:DamageTarget(target: any, amount: number, source: any): number
	if target == nil then
		return 0
	end
	if target.Kind == "Player" then
		return self:DamagePlayer(target, amount, source)
	elseif target.Kind == "Enemy" then
		return self:DamageEnemy(target, amount, source)
	end
	if not target:IsAlive() then
		return 0
	end
	return target:TakeDamage(amount, source)
end

function DamageService:DamageEnemiesInRadius(
	match: any,
	center: Vector3,
	radius: number,
	baseDamage: number,
	source: any,
	options: { [string]: any }?
): { any }
	local opts = options or {}
	local minFalloff = opts.MinFalloff or 1
	local includeUnderground = opts.IncludeUnderground == true
	local includeAir = opts.IncludeAir ~= false
	local maxTargets = opts.MaxTargets or math.huge
	local coneDirection: Vector3? = opts.ConeDirection
	local halfAngle = (opts.ConeAngle or 360) / 2

	local candidates = Services.EnemyService:GetEnemiesInRadius(match, center, radius, function(enemy)
		if enemy.Underground and not includeUnderground then
			return false
		end
		if enemy.IsAir and not includeAir then
			return false
		end
		if coneDirection and halfAngle < 180 then
			local toEnemy = enemy:GetPosition() - center
			if MathUtil.Flat(toEnemy).Magnitude > 1 and MathUtil.AngleBetweenFlat(coneDirection, toEnemy) > halfAngle then
				return false
			end
		end
		return true
	end)

	table.sort(candidates, function(a, b)
		return (a:GetPosition() - center).Magnitude < (b:GetPosition() - center).Magnitude
	end)

	local hit = {}
	for _, enemy in candidates do
		if #hit >= maxTargets then
			break
		end
		local distance = (enemy:GetPosition() - center).Magnitude
		local falloff = MathUtil.Lerp(1, minFalloff, math.clamp(distance / math.max(radius, 0.01), 0, 1))
		local dealt = self:DamageEnemy(enemy, baseDamage * falloff, source)
		if dealt > 0 then
			table.insert(hit, enemy)
			if opts.Effect and enemy:IsAlive() then
				Services.StatusEffectService:Apply(enemy, opts.Effect, { Duration = opts.EffectDuration, Source = source })
			end
			if opts.Knockback and enemy:IsAlive() then
				local direction = MathUtil.FlatDirection(center, enemy:GetPosition())
				if direction.Magnitude < 0.5 then
					direction = coneDirection and MathUtil.Flat(coneDirection).Unit or Vector3.new(0, 0, -1)
				end
				enemy:ApplyKnockback(direction * opts.Knockback)
			end
		end
	end
	return hit
end

return DamageService
