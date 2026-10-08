--!strict
--[[
	EnemyBase
	Path: ServerScriptService.Server.AI.EnemyBase

	Base class for every enemy. Owns the model, health, status-effect integration,
	attack cadence, damage contributions (for assists), death and cleanup. Archetype
	classes (ZombieFarmer, ZombieMole, ...) inherit from it and implement Think().

	Lifecycle:
		new(match, definition, stats, spawnCFrame, options) -> Spawn() -> Start()
		-> Update(now, dt) from AIScheduler -> Die(killer) | Despawn(reason) -> Destroy()

	Security/robustness:
	  * the root's network owner is forced to the server (clients can never drive NPC
	    physics), re-applied after any physics state change
	  * health lives on the server object; attributes are a read-only mirror
	  * falling below the arena kill plane despawns the enemy
	  * every connection/instance is owned by the enemy's Janitor

	Dependencies: EnemyConfig, MatchConfig, Attributes, CollisionGroup, Janitor, Signal,
	              ModelFactory, CollisionGroups, TargetSelector;
	              Registry: StatusEffectService, DamageService, EffectService

	API:
		EnemyBase.new(match, definition, stats, spawnCFrame, options) -> EnemyBase
		enemy:Spawn() -> boolean
		enemy:Start() / enemy:Stop()
		enemy:Update(now, dt)              -- AIScheduler entry point
		enemy:Think(now, dt)               -- implemented by subclasses
		enemy:SetTarget(target) / enemy:GetTarget()
		enemy:RefreshTarget(now, options?) -> target?
		enemy:TakeDamage(amount, source) -> number
		enemy:ApplyKnockback(vector)
		enemy:GetPosition() -> Vector3
		enemy:IsAlive() -> boolean
		enemy:GetEffectiveSpeed() -> number
		enemy:CanAttack(now) -> boolean / enemy:MarkAttacked(now)
		enemy:AttackTarget(target, now) -> boolean
		enemy:MakeSource() -> DamageSource
		enemy:FaceTowards(position)
		enemy:Die(killer?) / enemy:Despawn(reason)
		enemy:Destroy()
		enemy.Died : Signal(enemy, killer)
		enemy.Removed : Signal(enemy, reason)
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local CollisionGroup = require(Shared.Constants.CollisionGroup)
local EnemyConfig = require(Shared.Config.EnemyConfig)
local Janitor = require(Shared.Classes.Janitor)
local MatchConfig = require(Shared.Config.MatchConfig)
local MathUtil = require(Shared.Utilities.MathUtil)
local Signal = require(Shared.Classes.Signal)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local CollisionGroups = require(Server.Systems.CollisionGroups)
local ModelFactory = require(Server.Systems.ModelFactory)
local TargetSelector = require(script.Parent.TargetSelector)

local TARGET_REFRESH_INTERVAL = 1.5

local EnemyBase = {}
EnemyBase.__index = EnemyBase

local nextUid = 0

export type SpawnOptions = { IsWaveEnemy: boolean?, Summoner: any? }

function EnemyBase.new(match: any, definition: any, stats: any, spawnCFrame: CFrame, options: SpawnOptions?)
	nextUid += 1
	local self = setmetatable({}, EnemyBase)
	self.Uid = `Enemy_{nextUid}`
	self.Kind = "Enemy"
	self.EnemyId = definition.Id
	self.Definition = definition
	self.Match = match
	self.Stats = stats
	self.MaxHealth = stats.MaxHealth
	self.Health = stats.MaxHealth
	self.SpawnCFrame = spawnCFrame
	self.IsWaveEnemy = if options and options.IsWaveEnemy ~= nil then options.IsWaveEnemy else true
	self.Summoner = options and options.Summoner
	self.IsBoss = definition.IsBoss == true
	self.IsAir = definition.MovementType == "Air"
	self.Underground = false
	self.MovementType = definition.MovementType
	self.UpdateInterval = definition.UpdateInterval or 0.2
	self.HitRadius = 2
	self.SpeedMultiplier = 1
	self.Target = nil :: any
	self.TargetRefreshAt = 0
	self.LastAttackAt = -math.huge
	self.Contributions = {} :: { [Player]: number }
	self.Janitor = Janitor.new()
	self.Died = Signal.new()
	self.Removed = Signal.new()
	self.Alive = false
	self.Dead = false
	self.Destroyed = false
	self.Model = nil :: Model?
	self.Root = nil :: BasePart?
	self.Humanoid = nil :: Humanoid?
	self._lastPosition = spawnCFrame.Position
	return self
end

-- Model / lifecycle ---------------------------------------------------------------------

function EnemyBase:Spawn(): boolean
	local model = ModelFactory.CreateEnemy(self.Definition)
	local root = model.PrimaryPart
	if root == nil then
		warn(`[EnemyBase] model for {self.EnemyId} has no PrimaryPart`)
		model:Destroy()
		return false
	end
	self.Model = self.Janitor:AddKeyed("Model", model)
	self.Root = root
	self.Humanoid = model:FindFirstChildOfClass("Humanoid")
	local extents = model:GetExtentsSize()
	self.HitRadius = math.max(1.5, math.max(extents.X, extents.Z) / 2)

	model:SetAttribute(Attributes.EnemyUid, self.Uid)
	model:SetAttribute(Attributes.EnemyId, self.EnemyId)
	model:SetAttribute(Attributes.MatchId, self.Match.Id)
	self:_publishHealth()

	CollisionGroups.SetModel(model, if self.IsAir then CollisionGroup.Ghost else CollisionGroup.Enemies)
	model:PivotTo(self.SpawnCFrame)
	model.Parent = self.Match.Folder:FindFirstChild("Enemies")
	self:_claimNetworkOwnership()

	local humanoid = self.Humanoid
	if humanoid then
		humanoid.MaxHealth = 1e9
		humanoid.Health = 1e9
		humanoid.WalkSpeed = self:GetEffectiveSpeed()
		for _, state in {
			Enum.HumanoidStateType.Climbing,
			Enum.HumanoidStateType.Swimming,
			Enum.HumanoidStateType.Seated,
			Enum.HumanoidStateType.FallingDown,
			Enum.HumanoidStateType.Ragdoll,
		} do
			humanoid:SetStateEnabled(state, false)
		end
		-- Health is owned by this object. A humanoid that dies by other means (void,
		-- explosion physics) is treated as a kill with no credit.
		self.Janitor:Connect(humanoid.Died, function()
			if self.Alive then
				self:Die(nil)
			end
		end)
	end
	self.Alive = true
	self:OnSpawned()
	return true
end

function EnemyBase:_claimNetworkOwnership()
	local root = self.Root
	if root and root:IsDescendantOf(Workspace) and not root.Anchored then
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
	end
end

-- Hook for subclasses (called once the model is in the world).
function EnemyBase:OnSpawned() end

function EnemyBase:Start()
	Services.EnemyService:Schedule(self)
end

function EnemyBase:Stop()
	Services.EnemyService:Unschedule(self)
end

function EnemyBase:OnSchedulerError(_err: any)
	self:Despawn("Error")
end

function EnemyBase:Update(now: number, dt: number)
	if not self.Alive then
		return
	end
	local root = self.Root
	if root == nil or root.Parent == nil then
		self:Despawn("ModelLost")
		return
	end
	self._lastPosition = root.Position
	if root.Position.Y < self.Match.Arena.FloorY - MatchConfig.Arena.KillPlaneDepth then
		self:Despawn("Fell")
		return
	end
	self:Think(now, dt)
end

-- State-specific think rates: AIScheduler reads UpdateInterval every time it
-- reschedules, so switching it on a state change takes effect on the next think.
-- Rates come from definition.StateUpdateIntervals[state] (fallback UpdateInterval).
function EnemyBase:BindStateUpdateIntervals(machine: any)
	local intervals = self.Definition.StateUpdateIntervals
	if intervals == nil then
		return
	end
	self.Janitor:Add(machine.StateChanged:Connect(function(newState: string)
		self.UpdateInterval = intervals[newState] or self.Definition.UpdateInterval or 0.2
	end))
end

function EnemyBase:Think(_now: number, _dt: number)
	error(`[EnemyBase] {self.EnemyId} must implement Think`)
end

-- Targeting ----------------------------------------------------------------------------

function EnemyBase:SetTarget(target: any)
	self.Target = target
end

function EnemyBase:GetTarget(): any
	return self.Target
end

function EnemyBase:RefreshTarget(now: number, options: any?): any
	local current = self.Target
	if now >= self.TargetRefreshAt or not TargetSelector.IsValid(self, current) then
		self.TargetRefreshAt = now + TARGET_REFRESH_INTERVAL
		self.Target = TargetSelector.Select(self, options)
	end
	return self.Target
end

-- Combat -----------------------------------------------------------------------------------

function EnemyBase:GetPosition(): Vector3
	local root = self.Root
	if root and root.Parent then
		return root.Position
	end
	return self._lastPosition
end

function EnemyBase:IsAlive(): boolean
	return self.Alive and not self.Dead
end

function EnemyBase:GetEffectiveSpeed(): number
	return self.Stats.Speed * self.SpeedMultiplier * Services.StatusEffectService:GetSpeedMultiplier(self)
end

function EnemyBase:GetAttackCooldown(): number
	return self.Definition.AttackCooldown / math.max(0.1, Services.StatusEffectService:GetAttackSpeedMultiplier(self))
end

function EnemyBase:CanAttack(now: number): boolean
	return now - self.LastAttackAt >= self:GetAttackCooldown()
end

function EnemyBase:MarkAttacked(now: number)
	self.LastAttackAt = now
end

function EnemyBase:MakeSource(): any
	return { Kind = "Enemy", Enemy = self, MovementType = self.MovementType, IsBoss = self.IsBoss }
end

-- Damage this enemy deals to one target, chosen by target kind.
function EnemyBase:GetDamageAgainst(target: any): number
	local kind = target.Kind
	if kind == "Player" then
		return self.Stats.Damage
	elseif kind == "Crop" then
		return self.Stats.CropDamage
	end
	return self.Stats.StructureDamage
end

-- Melee hit if the target is within reach. Returns true when the attack happened.
function EnemyBase:AttackTarget(target: any, now: number): boolean
	if target == nil or not target:IsAlive() or not self:CanAttack(now) then
		return false
	end
	local position = target:GetPosition()
	if position == nil then
		return false
	end
	local reach = (self.Definition.AttackRange or 5) + TargetSelector.GetRadius(target) + self.HitRadius
	if MathUtil.FlatDistance(position, self:GetPosition()) > reach then
		return false
	end
	self:MarkAttacked(now)
	self:FaceTowards(position)
	Services.DamageService:DamageTarget(target, self:GetDamageAgainst(target), self:MakeSource())
	return true
end

function EnemyBase:TakeDamage(amount: number, source: any): number
	if not self:IsAlive() or amount <= 0 then
		return 0
	end
	local scaled = amount
	if self.Underground then
		if not (source and source.CanHitUnderground) then
			return 0
		end
		scaled *= self.Definition.UndergroundDamageMultiplier or 0.5
	end
	local dealt = math.min(self.Health, scaled)
	self.Health -= dealt
	local attacker = source and source.Player
	if attacker then
		self.Contributions[attacker] = (self.Contributions[attacker] or 0) + dealt
	end
	self:_publishHealth()
	self:OnDamaged(dealt, source)
	if self.Health <= 0 then
		self:Die(attacker)
	end
	return dealt
end

-- Hook for subclasses (e.g. the mole fights back when interrupted).
function EnemyBase:OnDamaged(_amount: number, _source: any) end

function EnemyBase:_publishHealth()
	local model = self.Model
	if model then
		model:SetAttribute(Attributes.Health, math.max(0, math.ceil(self.Health)))
		model:SetAttribute(Attributes.MaxHealth, self.MaxHealth)
	end
end

function EnemyBase:ApplyKnockback(vector: Vector3)
	local resistance = self.Definition.KnockbackResistance or 0
	local root = self.Root
	if resistance >= 1 or root == nil or self.Underground then
		return
	end
	root.AssemblyLinearVelocity += vector * (1 - resistance) + Vector3.new(0, 12, 0)
end

function EnemyBase:OnStatusEffectsChanged()
	local humanoid = self.Humanoid
	if humanoid then
		humanoid.WalkSpeed = self:GetEffectiveSpeed()
	end
end

function EnemyBase:FaceTowards(position: Vector3)
	local root = self.Root
	if root == nil then
		return
	end
	local direction = MathUtil.FlatDirection(root.Position, position)
	if direction.Magnitude > 0.5 and self.Humanoid then
		-- Rotating the root directly keeps the humanoid's physics untouched.
		root.CFrame = CFrame.lookAt(root.Position, root.Position + direction)
	end
end

-- Death / removal ---------------------------------------------------------------------------

-- Hook for subclasses; runs before Died fires (e.g. a crow drops its loot).
function EnemyBase:OnDeath(_killer: Player?) end

function EnemyBase:Die(killer: Player?)
	if self.Dead then
		return
	end
	self.Dead = true
	self.Alive = false
	self.Health = 0
	self:_publishHealth()
	self:Stop()
	local ok, err = pcall(self.OnDeath, self, killer)
	if not ok then
		warn(`[EnemyBase] OnDeath failed for {self.EnemyId}: {err}`)
	end
	Services.EffectService:PlayAt(self.Match, "Death", self:GetPosition(), { EnemyId = self.EnemyId, IsBoss = self.IsBoss })
	self.Died:Fire(self, killer)

	-- Leave the corpse briefly for feedback, then clean everything up.
	local model = self.Model
	if model then
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.CanCollide = false
				descendant.CanQuery = false
			end
		end
		self.Model = nil
		self.Janitor:Detach("Model")
		Debris:AddItem(model, EnemyConfig.CorpseLifetime)
	end
	self:Destroy()
end

function EnemyBase:Despawn(reason: string)
	if self.Destroyed then
		return
	end
	self.Alive = false
	self.Dead = true
	self:Stop()
	self.Removed:Fire(self, reason)
	self:Destroy()
end

-- Hook for subclasses to release their own resources.
function EnemyBase:OnDestroy() end

function EnemyBase:Destroy()
	if self.Destroyed then
		return
	end
	self.Destroyed = true
	self.Alive = false
	self:Stop()
	pcall(self.OnDestroy, self)
	Services.StatusEffectService:ClearTarget(self)
	self.Janitor:Destroy()
	self.Died:Destroy()
	self.Removed:Destroy()
	self.Target = nil
	self.Summoner = nil
	table.clear(self.Contributions)
end

return EnemyBase
