--!strict
--[[
	Weapon
	Path: ServerScriptService.Server.Classes.Weapons.Weapon

	Base class for class weapons. Holds server-side cooldowns and the shared guard
	logic; subclasses implement PerformAttack / PerformAbility. Cooldowns are checked
	against the server clock with a small tolerance for network jitter, so a client
	firing faster than allowed simply has its extra requests ignored.

	Subclasses: MagicStaff (ProjectileAoE), ReaperScythe (MeleeCleave).

	Dependencies: WeaponConfig, ResultCode, Janitor, MathUtil

	API:
		Weapon.new(session, definition, ability) -> Weapon
		weapon:TryAttack(aimPoint, now) -> (boolean, code)
		weapon:TryAbility(aimPoint, now) -> (boolean, code)
		weapon:GetOrigin() -> Vector3?
		weapon:GetAimDirection(aimPoint) -> Vector3     (flat unit vector)
		weapon:ClampAim(aimPoint, maxRange) -> Vector3
		weapon:MakeSource(kind) -> DamageSource
		weapon:Destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Janitor = require(Shared.Classes.Janitor)
local MathUtil = require(Shared.Utilities.MathUtil)
local ResultCode = require(Shared.Constants.ResultCode)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local Weapon = {}
Weapon.__index = Weapon

function Weapon.new(session: any, definition: any, ability: any)
	local self = setmetatable({}, Weapon)
	self.Session = session
	self.Definition = definition
	self.Ability = ability
	self.Janitor = Janitor.new()
	self.Tool = nil :: Tool?
	self.ReadyAt = 0
	self.AbilityReadyAt = 0
	self.Destroyed = false
	return self
end

function Weapon:SetTool(tool: Tool)
	self.Tool = self.Janitor:Add(tool)
end

function Weapon:GetOrigin(): Vector3?
	local root = self.Session:GetRoot()
	if root == nil then
		return nil
	end
	return root.Position + Vector3.new(0, 1.5, 0)
end

function Weapon:GetAimDirection(aimPoint: Vector3): Vector3
	local root = self.Session:GetRoot()
	if root == nil then
		return Vector3.new(0, 0, -1)
	end
	local direction = MathUtil.FlatDirection(root.Position, aimPoint)
	if direction.Magnitude < 0.5 then
		direction = MathUtil.Flat(root.CFrame.LookVector)
		if direction.Magnitude < 1e-3 then
			return Vector3.new(0, 0, -1)
		end
		direction = direction.Unit
	end
	return direction
end

function Weapon:ClampAim(aimPoint: Vector3, maxRange: number): Vector3
	local origin = self:GetOrigin()
	if origin == nil then
		return aimPoint
	end
	local offset = aimPoint - origin
	if offset.Magnitude > maxRange then
		return origin + offset.Unit * maxRange
	end
	return aimPoint
end

function Weapon:MakeSource(kind: string): any
	return {
		Kind = kind,
		Player = self.Session.Player,
		Id = if kind == "Ability" and self.Ability then self.Ability.Id else self.Definition.Id,
	}
end

function Weapon:TryAttack(aimPoint: Vector3, now: number): (boolean, string)
	if self.Destroyed then
		return false, ResultCode.NotAllowed
	end
	if now + WeaponConfig.CooldownTolerance < self.ReadyAt then
		return false, ResultCode.Cooldown
	end
	self.ReadyAt = now + self.Definition.Cooldown
	self:PerformAttack(aimPoint)
	return true, ResultCode.Ok
end

function Weapon:TryAbility(aimPoint: Vector3, now: number): (boolean, string)
	if self.Destroyed or self.Ability == nil then
		return false, ResultCode.NotAllowed
	end
	if now + WeaponConfig.CooldownTolerance < self.AbilityReadyAt then
		return false, ResultCode.Cooldown
	end
	self.AbilityReadyAt = now + self.Ability.Cooldown
	self:PerformAbility(aimPoint)
	return true, ResultCode.Ok
end

function Weapon:PerformAttack(_aimPoint: Vector3)
	error("Weapon:PerformAttack must be implemented by a subclass")
end

function Weapon:PerformAbility(_aimPoint: Vector3)
	error("Weapon:PerformAbility must be implemented by a subclass")
end

function Weapon:Destroy()
	if self.Destroyed then
		return
	end
	self.Destroyed = true
	self.Janitor:Destroy()
end

return Weapon
