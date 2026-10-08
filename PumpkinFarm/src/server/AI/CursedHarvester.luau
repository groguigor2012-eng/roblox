--!strict
--[[
	CursedHarvester
	Path: ServerScriptService.Server.AI.CursedHarvester

	Boss of every 10th wave.
		* Intro: rises for IntroDuration (anchored, announced to the match)
		* Objective priority: defenses within DefenseSeekRadius, then crops, then the
		  Great Pumpkin; players only when they get close
		* Crush: any barricade inside CrushRadius, hit by the sweep or attacked is
		  destroyed instantly (barricades never soak boss damage)
		* Sweep: every SweepCooldown, a scythe sweep damages players, crops and
		  defenses within SweepRadius
		* Aura: every AuraPulseInterval nearby enemies receive the "BossAura" status
		  with the speed / attack-speed buffs from this boss's EnemyConfig (AuraRadius,
		  AuraSpeedBuff, AuraAttackSpeedBuff); it expires shortly after leaving the radius
		* Enrage below EnrageThreshold health: faster movement
		* Boss HUD: BossActive/BossName/BossHealth/BossMaxHealth/BossAuraRadius/BossEnraged
		  attributes on the match folder
		* Death: RewardService.OnBossKilled (coins + Cursed Core into the chest)

	Dependencies: EnemyBase, Navigator, TargetSelector, Attributes;
	              Registry: EnemyService, DefenseService, CropService, DamageService,
	              StatusEffectService, RewardService, EffectService
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Constants.Attributes)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local EnemyBase = require(script.Parent.EnemyBase)
local Navigator = require(script.Parent.Navigator)
local TargetSelector = require(script.Parent.TargetSelector)

local CursedHarvester = setmetatable({}, { __index = EnemyBase })
CursedHarvester.__index = CursedHarvester

function CursedHarvester.new(match: any, definition: any, stats: any, spawnCFrame: CFrame, options: any?)
	local self = EnemyBase.new(match, definition, stats, spawnCFrame, options)
	return setmetatable(self, CursedHarvester)
end

function CursedHarvester:OnSpawned()
	local definition = self.Definition
	self.Navigator = self.Janitor:Add(Navigator.new(self, definition.Agent))
	self.SpawnedAt = os.clock()
	self.NextSweepAt = self.SpawnedAt + definition.IntroDuration + 2
	self.NextAuraAt = 0
	self.Enraged = false
	local root = self.Root :: BasePart
	root.Anchored = true

	local match = self.Match
	match:SetAttribute(Attributes.BossActive, true)
	match:SetAttribute(Attributes.BossName, definition.DisplayName)
	match:SetAttribute(Attributes.BossMaxHealth, self.MaxHealth)
	match:SetAttribute(Attributes.BossHealth, self.Health)
	match:SetAttribute(Attributes.BossAuraRadius, definition.AuraRadius)
	match:SetAttribute(Attributes.BossEnraged, false)
	match:FireAll("MatchEvent", "BossSpawned", { Name = definition.DisplayName })
end

function CursedHarvester:_clearBossHud()
	local match = self.Match
	if match.Destroyed then
		return
	end
	match:SetAttribute(Attributes.BossActive, false)
	match:SetAttribute(Attributes.BossEnraged, false)
end

function CursedHarvester:OnDamaged(_amount: number, _source: any)
	self.Match:SetAttribute(Attributes.BossHealth, math.max(0, math.ceil(self.Health)))
	local definition = self.Definition
	if not self.Enraged and self.Health > 0 and self.Health / self.MaxHealth <= definition.EnrageThreshold then
		self.Enraged = true
		self.SpeedMultiplier = definition.EnrageSpeedMultiplier
		self:OnStatusEffectsChanged()
		self.Match:SetAttribute(Attributes.BossEnraged, true)
		self.Match:Notify("The Cursed Harvester is ENRAGED!", "Warning")
	end
end

-- Boss objective: nearest defense in range, else the normal priority list.
function CursedHarvester:_selectObjective(now: number): any
	local definition = self.Definition
	local current = self.Target
	if current and current:IsAlive() and now < self.TargetRefreshAt then
		return current
	end
	self.TargetRefreshAt = now + 1
	local position = self:GetPosition()
	local nearestDefense, nearestDistance = nil, definition.DefenseSeekRadius
	for _, defense in Services.DefenseService:GetDefenses(self.Match) do
		if defense:IsAlive() then
			local distance = (defense:GetPosition() - position).Magnitude
			if distance < nearestDistance then
				nearestDefense, nearestDistance = defense, distance
			end
		end
	end
	self.Target = nearestDefense or TargetSelector.Select(self)
	return self.Target
end

function CursedHarvester:_crushBarricade(defense: any)
	if defense.Kind == "Barricade" and defense:IsAlive() then
		local position = defense:GetPosition()
		Services.DefenseService:DestroyDefense(defense, "Crushed")
		Services.EffectService:PlayAt(self.Match, "BossCrush", position, {})
	end
end

function CursedHarvester:_crush()
	local definition = self.Definition
	for _, defense in Services.DefenseService:GetDefensesInRadius(self.Match, self:GetPosition(), definition.CrushRadius) do
		self:_crushBarricade(defense)
	end
end

-- Barricades never soak boss hits: anything that would damage one crushes it outright.
function CursedHarvester:AttackTarget(target: any, now: number): boolean
	if target and target.Kind == "Barricade" and target:IsAlive() then
		local reach = (self.Definition.AttackRange or 5) + TargetSelector.GetRadius(target) + self.HitRadius
		if (target:GetPosition() - self:GetPosition()).Magnitude <= reach then
			self:MarkAttacked(now)
			self:FaceTowards(target:GetPosition())
			self:_crushBarricade(target)
			return true
		end
		return false
	end
	return EnemyBase.AttackTarget(self, target, now)
end

function CursedHarvester:_sweep(now: number)
	local definition = self.Definition
	local match = self.Match
	local position = self:GetPosition()
	local radius = definition.SweepRadius
	local source = self:MakeSource()

	local hitSomething = false
	for _, session in match:GetLivingSessions() do
		local playerPosition = session:GetPosition()
		if playerPosition and (playerPosition - position).Magnitude <= radius then
			Services.DamageService:DamagePlayer(session, self.Stats.Damage, source)
			hitSomething = true
		end
	end
	for _, crop in Services.CropService:GetCropsInRadius(match, position, radius) do
		Services.DamageService:DamageTarget(crop, self.Stats.CropDamage, source)
		hitSomething = true
	end
	for _, defense in Services.DefenseService:GetDefensesInRadius(match, position, radius) do
		if defense.Kind == "Barricade" then
			self:_crushBarricade(defense)
		else
			Services.DamageService:DamageTarget(defense, self.Stats.StructureDamage, source)
		end
		hitSomething = true
	end
	local core = match.Core
	if core and core:IsAlive() and (core:GetPosition() - position).Magnitude <= radius + core.Radius then
		Services.DamageService:DamageTarget(core, self.Stats.StructureDamage, source)
		hitSomething = true
	end
	if hitSomething then
		self.NextSweepAt = now + self:GetAttackCooldown() + definition.SweepCooldown
		Services.EffectService:PlayAt(match, "BossSweep", position, { Radius = radius })
	end
end

function CursedHarvester:_pulseAura()
	local definition = self.Definition
	for _, enemy in Services.EnemyService:GetEnemiesInRadius(self.Match, self:GetPosition(), definition.AuraRadius) do
		if enemy ~= self then
			Services.StatusEffectService:Apply(enemy, "BossAura", {
				Source = self,
				Overrides = {
					SpeedMultiplier = definition.AuraSpeedBuff,
					AttackSpeedMultiplier = definition.AuraAttackSpeedBuff,
				},
			})
		end
	end
end

function CursedHarvester:Think(now: number, _dt: number)
	local definition = self.Definition
	local root = self.Root :: BasePart
	if now - self.SpawnedAt < definition.IntroDuration then
		return
	end
	if root.Anchored then
		root.Anchored = false
		self:_claimNetworkOwnership()
		self.Match:Notify("The Cursed Harvester rises! Protect the farm!", "Warning", 5)
	end

	if now >= self.NextAuraAt then
		self.NextAuraAt = now + definition.AuraPulseInterval
		self:_pulseAura()
	end
	self:_crush()
	if now >= self.NextSweepAt then
		self:_sweep(now)
	end

	local target = self:_selectObjective(now)
	if target == nil then
		self.Navigator:Stop()
		return
	end
	if self:AttackTarget(target, now) then
		return
	end
	local blocking = self.Navigator:GetBlockingDefense(definition.CrushRadius + 4)
	if blocking and blocking:IsAlive() then
		self:AttackTarget(blocking, now)
	end
	self.Navigator:SetGoal(TargetSelector.GetApproachPoint(self, target), definition.AttackRange * 0.8)
	self.Navigator:Step(now)
end

function CursedHarvester:OnDeath(_killer: Player?)
	self:_clearBossHud()
	Services.RewardService:OnBossKilled(self.Match, self)
end

function CursedHarvester:OnDestroy()
	self:_clearBossHud()
end

return CursedHarvester
