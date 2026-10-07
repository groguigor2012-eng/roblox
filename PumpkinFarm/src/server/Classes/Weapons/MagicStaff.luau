--!strict
--[[
	MagicStaff
	Path: ServerScriptService.Server.Classes.Weapons.MagicStaff

	Witch class weapon (ProjectileAoE). Attack: a hex bolt simulated by ProjectileSystem
	from the caster toward the aim point; on impact it explodes for AOERadius damage
	with linear falloff down to MinFalloff at the edge, plus DirectHitBonus on the enemy
	it struck. The blast reaches buried moles (reduced by their underground multiplier)
	and flying crows.

	Ability (HexNova): instant curse at the aim point (clamped to MaxRange): damage and
	the Hexed slow in a radius.

	Dependencies: Weapon; Registry: DamageService, EffectService
	Systems: ProjectileSystem
]]

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local ProjectileSystem = require(Server.Systems.ProjectileSystem)
local Weapon = require(script.Parent.Weapon)

local MagicStaff = setmetatable({}, { __index = Weapon })
MagicStaff.__index = MagicStaff

function MagicStaff.new(session: any, definition: any, ability: any)
	local self = Weapon.new(session, definition, ability)
	return setmetatable(self, MagicStaff)
end

function MagicStaff:PerformAttack(aimPoint: Vector3)
	local session = self.Session
	local match = session.Match
	local origin = self:GetOrigin()
	if match == nil or origin == nil then
		return
	end
	local definition = self.Definition
	local target = self:ClampAim(aimPoint, definition.MaxRange)
	local offset = target - origin
	local direction = if offset.Magnitude > 0.1 then offset.Unit else self:GetAimDirection(aimPoint)
	local distance = math.max(offset.Magnitude, 4)
	local spawnOrigin = origin + direction * 2

	ProjectileSystem.Fire({
		Match = match,
		Origin = spawnOrigin,
		Velocity = direction * definition.ProjectileSpeed,
		Gravity = 0,
		Radius = definition.ProjectileRadius,
		MaxTime = distance / definition.ProjectileSpeed,
		HitEnemies = true,
		HitPlayers = false,
		IgnoreUnderground = true,
		Style = "Hex",
		Color = definition.Visual.GlowColor,
		OnHit = function(position: Vector3, enemy: any?)
			-- A bolt already in flight still lands if the caster died meanwhile.
			if match.Destroyed then
				return
			end
			local source = self:MakeSource("Weapon")
			source.CanHitUnderground = true
			if enemy and enemy:IsAlive() then
				Services.DamageService:DamageEnemy(enemy, definition.Damage * definition.DirectHitBonus, source)
			end
			Services.DamageService:DamageEnemiesInRadius(match, position, definition.AOERadius, definition.Damage, source, {
				MinFalloff = definition.MinFalloff,
				IncludeUnderground = true,
				IncludeAir = true,
			})
			Services.EffectService:PlayAt(match, "Explosion", position, {
				Radius = definition.AOERadius,
				Color = definition.Visual.GlowColor,
			})
		end,
	})
end

function MagicStaff:PerformAbility(aimPoint: Vector3)
	local session = self.Session
	local match = session.Match
	local ability = self.Ability
	if match == nil or ability == nil then
		return
	end
	local center = self:ClampAim(aimPoint, ability.MaxRange)
	local source = self:MakeSource("Ability")
	source.CanHitUnderground = true
	Services.DamageService:DamageEnemiesInRadius(match, center, ability.Radius, ability.Damage, source, {
		MinFalloff = 1,
		IncludeUnderground = true,
		IncludeAir = true,
		Effect = ability.Effect,
	})
	Services.EffectService:PlayAt(match, "HexNova", center, { Radius = ability.Radius })
end

return MagicStaff
