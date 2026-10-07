--!strict
--[[
	Sentry
	Path: ServerScriptService.Server.Classes.Sentry

	Automated turret. SentryService calls Update(now) at a fixed rate.
		Bolt  (Pumpkin Sentry): hits the nearest visible enemy in range, flying ones
		      included when CanTargetAir; buried moles are never targetable
		Pulse (Hex Lantern):   damages and Chills every ground enemy in range
	Kill credit goes to the player who built it (if still in the match).
	Stats scale with upgrade level (DamageMultiplier / RangeMultiplier).

	Dependencies: Defense; Registry: EnemyService, DamageService,
	              StatusEffectService, EffectService
]]

local Workspace = game:GetService("Workspace")

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local Defense = require(script.Parent.Defense)

local Sentry = setmetatable({}, { __index = Defense })
Sentry.__index = Sentry

function Sentry.new(match: any, definition: any, cframe: CFrame, owner: Player?, onDepleted: (any) -> ())
	local self = Defense.new(match, definition, cframe, owner, onDepleted)
	setmetatable(self, Sentry)
	self.NextFireAt = 0
	self.Head = self.Model:FindFirstChild("Head") :: BasePart?
	self.MuzzlePosition = if self.Head then self.Head.CFrame.Position else self.Position + Vector3.new(0, definition.Size.Y, 0)
	self._sightParams = RaycastParams.new()
	self._sightParams.FilterType = Enum.RaycastFilterType.Include
	self._sightParams.FilterDescendantsInstances = { match.Arena.PropsFolder, match.Arena.GroundFolder }
	return self
end

function Sentry:GetRange(): number
	return self.Definition.Range * self:GetMultiplier("RangeMultiplier")
end

function Sentry:GetDamage(): number
	return self.Definition.Damage * self:GetMultiplier("DamageMultiplier")
end

function Sentry:_source(): any
	local owner = self.Owner
	return {
		Kind = "Sentry",
		Id = self.DefenseId,
		Player = if owner and self.Match.Sessions[owner] then owner else nil,
	}
end

function Sentry:_canSee(position: Vector3): boolean
	local from = self.MuzzlePosition
	return Workspace:Raycast(from, position - from, self._sightParams) == nil
end

function Sentry:_aimAt(position: Vector3)
	local head = self.Head
	if head then
		local headPosition = head.CFrame.Position
		local flat = Vector3.new(position.X, headPosition.Y, position.Z)
		if (flat - headPosition).Magnitude > 0.1 then
			head.CFrame = CFrame.lookAt(headPosition, flat)
		end
	end
end

function Sentry:Update(now: number)
	if not self:IsAlive() or now < self.NextFireAt then
		return
	end
	local definition = self.Definition
	local match = self.Match
	local range = self:GetRange()

	if definition.SentryType == "Pulse" then
		local hit = Services.DamageService:DamageEnemiesInRadius(match, self.Position, range, self:GetDamage(), self:_source(), {
			IncludeUnderground = false,
			IncludeAir = definition.CanTargetAir,
			Effect = definition.Effect,
		})
		if #hit > 0 then
			self.NextFireAt = now + definition.FireInterval
			Services.EffectService:PlayAt(match, "LanternPulse", self.Position, { Radius = range })
		end
		return
	end

	local target = Services.EnemyService:GetNearestEnemy(match, self.Position, range, function(enemy)
		if enemy.Underground or (enemy.IsAir and not definition.CanTargetAir) then
			return false
		end
		return self:_canSee(enemy:GetPosition())
	end)
	if target == nil then
		return
	end
	self.NextFireAt = now + definition.FireInterval
	local targetPosition = target:GetPosition()
	self:_aimAt(targetPosition)
	Services.DamageService:DamageEnemy(target, self:GetDamage(), self:_source())
	Services.EffectService:PlayAt(match, "SentryBolt", self.MuzzlePosition, {
		From = self.MuzzlePosition,
		To = targetPosition,
		Color = definition.Color,
	})
end

-- Upgraded sentries grow slightly so their level reads at a glance.
function Sentry:OnUpgraded()
	local head = self.Head
	if head then
		head.Size *= 1.08
		self.MuzzlePosition = head.CFrame.Position
	end
end

return Sentry
