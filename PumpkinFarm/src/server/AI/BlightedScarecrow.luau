--!strict
--[[
	BlightedScarecrow
	Path: ServerScriptService.Server.AI.BlightedScarecrow

	Leaper. Hunts players and vaults over barricades.

		Chasing --(barricade ahead | target in leap band, cooldown ready)--> LeapWindup
		LeapWindup (telegraph at landing spot) -> Leaping (ballistic, Ghost collision so
		walls are cleared) -> Landing (shockwave: damage + 2 s server-authoritative stun
		through StunService, heavy damage to defenses) -> Recovering -> Chasing

	Landing spots are validated with a downward raycast against the arena ground before
	leaping, so a scarecrow never jumps out of the map. Stun stacking is impossible:
	StunService refuses to stun a stunned or recently-stunned player.

	Dependencies: EnemyBase, Navigator, TargetSelector, StateMachine, MathUtil,
	              CollisionGroup, CollisionGroups;
	              Registry: StunService, DamageService, DefenseService, EffectService
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local CollisionGroup = require(Shared.Constants.CollisionGroup)
local MathUtil = require(Shared.Utilities.MathUtil)
local StateMachine = require(Shared.Classes.StateMachine)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local CollisionGroups = require(Server.Systems.CollisionGroups)
local EnemyBase = require(script.Parent.EnemyBase)
local Navigator = require(script.Parent.Navigator)
local TargetSelector = require(script.Parent.TargetSelector)

local BlightedScarecrow = setmetatable({}, { __index = EnemyBase })
BlightedScarecrow.__index = BlightedScarecrow

function BlightedScarecrow.new(match: any, definition: any, stats: any, spawnCFrame: CFrame, options: any?)
	local self = EnemyBase.new(match, definition, stats, spawnCFrame, options)
	return setmetatable(self, BlightedScarecrow)
end

function BlightedScarecrow:OnSpawned()
	self.Navigator = self.Janitor:Add(Navigator.new(self, self.Definition.Agent))
	self.LeapReadyAt = 0
	self.LandingPoint = nil :: Vector3?
	self.Now = os.clock()
	local humanoid = self.Humanoid :: Humanoid
	self.StandHeight = humanoid.HipHeight + (self.Root :: BasePart).Size.Y / 2

	self._groundParams = RaycastParams.new()
	self._groundParams.FilterType = Enum.RaycastFilterType.Include
	self._groundParams.FilterDescendantsInstances = { self.Match.Arena.GroundFolder }
	self._defenseParams = RaycastParams.new()
	self._defenseParams.FilterType = Enum.RaycastFilterType.Include
	self._defenseParams.FilterDescendantsInstances = { self.Match.Folder:FindFirstChild("Defenses") :: Instance }

	self.Machine = self.Janitor:Add(self:_buildMachine())
	self.Machine:Start()
end

function BlightedScarecrow:Think(now: number, dt: number)
	self.Now = now
	self.Machine:Update(dt)
end

-- Returns a ground point to land on near `desired`, or nil if there is no floor.
function BlightedScarecrow:_validLanding(desired: Vector3): Vector3?
	local origin = Vector3.new(desired.X, self.Match.Arena.FloorY + 60, desired.Z)
	local result = Workspace:Raycast(origin, Vector3.new(0, -120, 0), self._groundParams)
	if result == nil then
		return nil
	end
	return result.Position
end

function BlightedScarecrow:_defenseBetween(targetPosition: Vector3): boolean
	local position = self:GetPosition()
	local offset = MathUtil.Flat(targetPosition - position)
	local distance = math.min(offset.Magnitude, self.Definition.LeapTriggerRange)
	if distance < 1 then
		return false
	end
	local result = Workspace:Raycast(position, offset.Unit * distance, self._defenseParams)
	return result ~= nil
end

function BlightedScarecrow:_tryStartLeap(target: any): boolean
	local definition = self.Definition
	if self.Now < self.LeapReadyAt then
		return false
	end
	local targetPosition = target:GetPosition()
	local position = self:GetPosition()
	local distance = MathUtil.FlatDistance(position, targetPosition)
	local blocked = self:_defenseBetween(targetPosition) or self.Navigator:GetBlockingDefense(definition.LeapTriggerRange) ~= nil
	local inBand = distance >= definition.LeapMinDistance and distance <= definition.LeapMaxDistance
	if not blocked and not inBand then
		return false
	end
	local direction = MathUtil.FlatDirection(position, targetPosition)
	local leapDistance = math.clamp(distance, definition.LeapMinDistance, definition.LeapMaxDistance)
	local landing = self:_validLanding(position + direction * leapDistance)
	if landing == nil then
		return false
	end
	self.LandingPoint = landing
	return true
end

function BlightedScarecrow:_scaledDamage(base: number): number
	return base * self.Stats.DamageFactor
end

function BlightedScarecrow:_land()
	local definition = self.Definition
	local match = self.Match
	local position = self:GetPosition()
	local source = self:MakeSource()

	for _, session in match:GetLivingSessions() do
		local playerPosition = session:GetPosition()
		if playerPosition and (playerPosition - position).Magnitude <= definition.LandingRadius then
			Services.DamageService:DamagePlayer(session, self:_scaledDamage(definition.LandingDamage), source)
			Services.StunService:TryStun(session, definition.StunDuration, source)
		end
	end
	for _, defense in Services.DefenseService:GetDefensesInRadius(match, position, definition.LandingRadius) do
		Services.DamageService:DamageTarget(defense, self:_scaledDamage(definition.LandingStructureDamage), source)
	end
	Services.EffectService:PlayAt(match, "Shockwave", position, { Radius = definition.LandingRadius })
end

function BlightedScarecrow:_buildMachine()
	local definition = self.Definition
	local states = {}

	states.Chasing = {
		Update = function(machine)
			local target = self:RefreshTarget(self.Now)
			if target == nil then
				self.Navigator:Stop()
				return
			end
			if self:AttackTarget(target, self.Now) then
				if target.Kind == "Player" then
					Services.StunService:TryStun(target, definition.StunDuration, self:MakeSource())
				end
				return
			end
			if self:_tryStartLeap(target) then
				machine:Transition("LeapWindup")
				return
			end
			local blocking = self.Navigator:GetBlockingDefense()
			if blocking and blocking:IsAlive() then
				self:AttackTarget(blocking, self.Now)
				return
			end
			self.Navigator:SetGoal(TargetSelector.GetApproachPoint(self, target), definition.AttackRange * 0.6)
			self.Navigator:Step(self.Now)
		end,
	}

	states.LeapWindup = {
		Enter = function()
			self.Navigator:Stop()
			local landing = self.LandingPoint :: Vector3
			self:FaceTowards(landing)
			Services.EffectService:PlayAt(self.Match, "Leap", landing, {
				Radius = definition.LandingRadius,
				Duration = definition.LeapWindup + definition.LeapDuration,
			})
		end,
		Update = function(machine)
			if machine:TimeInState() >= definition.LeapWindup then
				machine:Transition("Leaping")
			end
		end,
	}

	states.Leaping = {
		Enter = function()
			local root = self.Root :: BasePart
			local humanoid = self.Humanoid :: Humanoid
			local landing = (self.LandingPoint :: Vector3) + Vector3.new(0, self.StandHeight, 0)
			humanoid.PlatformStand = true
			CollisionGroups.SetModel(self.Model :: Model, CollisionGroup.Ghost)
			root.AssemblyLinearVelocity = MathUtil.BallisticVelocity(root.Position, landing, definition.LeapDuration, Workspace.Gravity)
			self:_claimNetworkOwnership()
		end,
		Update = function(machine)
			if machine:TimeInState() >= definition.LeapDuration then
				machine:Transition("Landing")
			end
		end,
		Exit = function()
			local root = self.Root
			local humanoid = self.Humanoid
			if root and self.LandingPoint then
				-- Snap to the validated landing spot so collision restore never embeds the
				-- scarecrow inside a wall it just cleared.
				root.AssemblyLinearVelocity = Vector3.zero
				root.CFrame = CFrame.new(self.LandingPoint + Vector3.new(0, self.StandHeight, 0)) * root.CFrame.Rotation
			end
			if humanoid then
				humanoid.PlatformStand = false
			end
			if self.Model then
				CollisionGroups.SetModel(self.Model, CollisionGroup.Enemies)
			end
		end,
	}

	states.Landing = {
		Enter = function()
			self.LeapReadyAt = self.Now + definition.LeapCooldown
			self:_land()
		end,
		Update = function(machine)
			if machine:TimeInState() >= 0.5 then
				machine:Transition("Chasing")
			end
		end,
	}

	states.Dying = {
		Enter = function()
			self.LandingPoint = nil
			self.Target = nil
		end,
	}

	return StateMachine.new({
		Name = `BlightedScarecrow_{self.Uid}`,
		Initial = "Chasing",
		States = states,
		Transitions = {
			Chasing = { "LeapWindup" },
			LeapWindup = { "Leaping" },
			Leaping = { "Landing" },
			Landing = { "Chasing" },
			["*"] = { "Dying" },
		},
	})
end

function BlightedScarecrow:OnDeath(_killer: Player?)
	if self.Machine and not self.Machine:Is("Dying") then
		self.Machine:Transition("Dying")
	end
end

return BlightedScarecrow
