--!strict
--[[
	Witch
	Path: ServerScriptService.Server.AI.Witch

	Backline spawner (enemy id "Witch"; unrelated to the player Witch class).
		* keeps a preferred distance band from the nearest player: retreats when
		  crowded, advances when too far, otherwise holds and casts
		* stays behind the frontline: the inner edge of the band is pushed out to
		  FrontlineBuffer beyond the closest allied ground enemy to that player, so
		  the horde is always between the witch and the defenders
		* throws slowing potions on a ballistic arc (ProjectileSystem with gravity) at
		  the predicted player position; the splash damages and applies "Slowed"
		  through StatusEffectService (server-authoritative)
		* summons ZombieFarmerMini minions on a cooldown, never exceeding MaxMinions
		  alive for this witch; minions count toward the wave
		* pushes away from other witches so they do not clump

	Dependencies: EnemyBase, Navigator, MathUtil;
	              Registry: EnemyService, DamageService, StatusEffectService, EffectService
	Systems: ProjectileSystem
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local MathUtil = require(Shared.Utilities.MathUtil)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local ProjectileSystem = require(Server.Systems.ProjectileSystem)
local EnemyBase = require(script.Parent.EnemyBase)
local Navigator = require(script.Parent.Navigator)

local Witch = setmetatable({}, { __index = EnemyBase })
Witch.__index = Witch

function Witch.new(match: any, definition: any, stats: any, spawnCFrame: CFrame, options: any?)
	local self = EnemyBase.new(match, definition, stats, spawnCFrame, options)
	return setmetatable(self, Witch)
end

function Witch:OnSpawned()
	self.Navigator = self.Janitor:Add(Navigator.new(self, self.Definition.Agent))
	self.Minions = {} :: { [any]: boolean }
	self.NextSummonAt = os.clock() + self.Definition.SummonCooldown * 0.5
	self.NextPotionAt = os.clock() + 2
	self._sightParams = RaycastParams.new()
	self._sightParams.FilterType = Enum.RaycastFilterType.Include
	self._sightParams.FilterDescendantsInstances = { self.Match.Arena.MapFolder }
end

function Witch:_nearestPlayer(): (any, number)
	local best, bestDistance = nil, math.huge
	local position = self:GetPosition()
	for _, session in self.Match:GetLivingSessions() do
		local playerPosition = session:GetPosition()
		if playerPosition then
			local distance = (playerPosition - position).Magnitude
			if distance < bestDistance then
				best, bestDistance = session, distance
			end
		end
	end
	return best, bestDistance
end

function Witch:_hasLineOfSight(to: Vector3): boolean
	local from = self:GetPosition() + Vector3.new(0, 2, 0)
	local result = Workspace:Raycast(from, to - from, self._sightParams)
	return result == nil
end

function Witch:_minionCount(): number
	local count = 0
	for minion in self.Minions do
		if minion:IsAlive() then
			count += 1
		else
			self.Minions[minion] = nil
		end
	end
	return count
end

function Witch:_summon(now: number)
	local definition = self.Definition
	self.NextSummonAt = now + definition.SummonCooldown
	local available = definition.MaxMinions - self:_minionCount()
	if available <= 0 then
		return
	end
	local origin = self:GetPosition()
	for index = 1, math.min(definition.SummonCount, available) do
		local angle = (index / definition.SummonCount) * math.pi * 2
		local offset = Vector3.new(math.cos(angle) * 4, 0, math.sin(angle) * 4)
		local spawnPosition = Vector3.new(origin.X + offset.X, self.Match.Arena.FloorY + 4, origin.Z + offset.Z)
		local minion = Services.EnemyService:SpawnEnemy(self.Match, definition.MinionId, CFrame.new(spawnPosition), {
			IsWaveEnemy = true,
			Summoner = self,
		})
		if minion then
			self.Minions[minion] = true
		end
	end
	Services.EffectService:PlayAt(self.Match, "Summon", origin, {})
end

function Witch:_throwPotion(target: any, now: number)
	local definition = self.Definition
	self.NextPotionAt = now + self:GetAttackCooldown()
	local root = target:GetRoot()
	if root == nil then
		return
	end
	-- Lead the target by its current velocity over the flight time.
	local flightTime = definition.PotionFlightTime
	local predicted = root.Position + MathUtil.Flat(root.AssemblyLinearVelocity) * flightTime * 0.8
	local origin = self:GetPosition() + Vector3.new(0, 3, 0)
	local gravity = Workspace.Gravity
	local velocity = MathUtil.BallisticVelocity(origin, predicted, flightTime, gravity)
	local match = self.Match
	local splashDamage = definition.PotionDamage * self.Stats.DamageFactor
	local source = self:MakeSource()

	self:FaceTowards(predicted)
	ProjectileSystem.Fire({
		Match = match,
		Origin = origin,
		Velocity = velocity,
		Gravity = gravity,
		Radius = 0.8,
		MaxTime = flightTime + 0.6,
		HitEnemies = false,
		HitPlayers = true,
		Style = "Potion",
		OnHit = function(position: Vector3)
			for _, session in match:GetLivingSessions() do
				local playerPosition = session:GetPosition()
				if playerPosition and (playerPosition - position).Magnitude <= definition.PotionSplashRadius then
					Services.DamageService:DamagePlayer(session, splashDamage, source)
					Services.StatusEffectService:Apply(session, definition.PotionEffect, { Source = source })
				end
			end
			Services.EffectService:PlayAt(match, "PotionSplash", position, { Radius = definition.PotionSplashRadius })
		end,
	})
end

-- Steering goal that keeps the witch inside its preferred band and apart from others.
function Witch:_desiredPosition(targetPosition: Vector3, distance: number): (Vector3?, number)
	local band = self.Definition.PreferredRange
	local position = self:GetPosition()
	local away = MathUtil.FlatDirection(targetPosition, position)
	local separation = Vector3.zero
	for _, other in Services.EnemyService:GetEnemiesInRadius(self.Match, position, self.Definition.SeparationRadius) do
		if other ~= self and other.EnemyId == self.EnemyId then
			separation += MathUtil.FlatDirection(other:GetPosition(), position)
		end
	end
	-- Behind the frontline: never closer to the player than the nearest ally (+buffer).
	local minimum = band[1]
	local frontline = math.huge
	for _, ally in Services.EnemyService:GetEnemiesInRadius(self.Match, targetPosition, band[2]) do
		if ally ~= self and ally.EnemyId ~= self.EnemyId and not ally.IsAir and not ally.IsBoss and not ally.Underground then
			frontline = math.min(frontline, (ally:GetPosition() - targetPosition).Magnitude)
		end
	end
	if frontline < math.huge then
		minimum = math.clamp(frontline + self.Definition.FrontlineBuffer, band[1], band[2] - 4)
	end
	if distance < minimum then
		return position + (away + separation) * 12, 2
	elseif distance > band[2] then
		return targetPosition + away * (band[2] - 4) + separation * 4, 3
	elseif separation.Magnitude > 0.1 then
		return position + separation * 6, 2
	end
	return nil, 0
end

function Witch:Think(now: number, _dt: number)
	local definition = self.Definition
	if now >= self.NextSummonAt then
		self:_summon(now)
	end

	local target, distance = self:_nearestPlayer()
	if target == nil then
		-- No players alive: drift toward the farm and wait.
		self.Navigator:SetGoal(self.Match.Arena.Center, definition.PreferredRange[2])
		self.Navigator:Step(now)
		return
	end
	self.Target = target
	local targetPosition = target:GetPosition()

	local goal, stopDistance = self:_desiredPosition(targetPosition, distance)
	if goal then
		local bounds = self.Match.Arena.Bounds
		local clamped = Vector3.new(
			math.clamp(goal.X, bounds.MinX, bounds.MaxX),
			goal.Y,
			math.clamp(goal.Z, bounds.MinZ, bounds.MaxZ)
		)
		self.Navigator:SetGoal(clamped, stopDistance)
		self.Navigator:Step(now)
	else
		self.Navigator:Stop()
		self:FaceTowards(targetPosition)
	end

	if now >= self.NextPotionAt and distance <= definition.AttackRange and self:_hasLineOfSight(targetPosition) then
		self:_throwPotion(target, now)
	end
end

function Witch:OnDestroy()
	if self.Minions then
		table.clear(self.Minions)
	end
end

return Witch
