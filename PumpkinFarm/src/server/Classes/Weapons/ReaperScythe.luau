--!strict
--[[
	ReaperScythe
	Path: ServerScriptService.Server.Classes.Weapons.ReaperScythe

	Knight class weapon (MeleeCleave). Attack: after a short wind-up (HitDelay) the
	server sweeps a cone of CleaveAngle degrees and CleaveRadius studs in the aimed
	direction around the character's CURRENT server position, hitting up to MaxTargets
	enemies with knockback. Buried moles cannot be hit by melee.

	Ability (ReapingWhirl): 360-degree sweep with larger radius and knockback.

	Dependencies: Weapon, LifeState; Registry: DamageService, EffectService,
	              StatusEffectService
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LifeState = require(ReplicatedStorage.Shared.Constants.LifeState)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local Weapon = require(script.Parent.Weapon)

local ReaperScythe = setmetatable({}, { __index = Weapon })
ReaperScythe.__index = ReaperScythe

function ReaperScythe.new(session: any, definition: any, ability: any)
	local self = Weapon.new(session, definition, ability)
	return setmetatable(self, ReaperScythe)
end

-- The swing lands after the wind-up only if the wielder is still able to fight.
function ReaperScythe:_canStillSwing(match: any): boolean
	local session = self.Session
	return not self.Destroyed
		and session.Match == match
		and session.LifeState == LifeState.InMatch
		and session:IsAlive()
		and not Services.StatusEffectService:BlocksAttacks(session)
end

function ReaperScythe:PerformAttack(aimPoint: Vector3)
	local session = self.Session
	local match = session.Match
	if match == nil then
		return
	end
	local definition = self.Definition
	local direction = self:GetAimDirection(aimPoint)
	local root = session:GetRoot()
	if root then
		Services.EffectService:PlayAt(match, "Slash", root.Position, {
			Direction = direction,
			Radius = definition.CleaveRadius,
			Angle = definition.CleaveAngle,
			Color = definition.Visual.GlowColor,
		})
	end

	task.delay(definition.HitDelay, function()
		if not self:_canStillSwing(match) then
			return
		end
		local origin = session:GetPosition()
		if origin == nil then
			return
		end
		Services.DamageService:DamageEnemiesInRadius(match, origin, definition.CleaveRadius, definition.Damage, self:MakeSource("Weapon"), {
			MinFalloff = 1,
			IncludeUnderground = false,
			IncludeAir = true,
			MaxTargets = definition.MaxTargets,
			Knockback = definition.Knockback,
			ConeDirection = direction,
			ConeAngle = definition.CleaveAngle,
		})
	end)
end

function ReaperScythe:PerformAbility(_aimPoint: Vector3)
	local session = self.Session
	local match = session.Match
	local ability = self.Ability
	local origin = session:GetPosition()
	if match == nil or ability == nil or origin == nil then
		return
	end
	Services.DamageService:DamageEnemiesInRadius(match, origin, ability.Radius, ability.Damage, self:MakeSource("Ability"), {
		MinFalloff = 1,
		IncludeUnderground = false,
		IncludeAir = true,
		MaxTargets = ability.MaxTargets,
		Knockback = ability.Knockback,
	})
	Services.EffectService:PlayAt(match, "Whirl", origin, { Radius = ability.Radius })
end

return ReaperScythe
