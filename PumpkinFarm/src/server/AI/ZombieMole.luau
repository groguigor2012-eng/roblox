--!strict
--[[
	ZombieMole
	Path: ServerScriptService.Server.AI.ZombieMole

	Breacher. Tunnels under the outer defenses and erupts next to the crop it wants.
	Implemented as an explicit StateMachine:

		Idle -> SelectingTarget -> EnteringUnderground -> UndergroundTraversal
		     -> Resurfacing -> AttackingCrop -> Retargeting -> (dig again | walk | attack)
		AttackingCrop -> Combat (a player interrupted it) -> Retargeting
		any -> Dying

	Underground navigation is real: UndergroundRouter raycasts the arena's Ground folder
	into a dig grid (bedrock rocks / foundations are impassable, map bounds enforced) and
	A* finds a tunnel to a validated resurface point beside the target. While buried the
	mole's body is hidden and Ghost-collided, a dirt mound tracks it on the surface,
	melee and sentries cannot hit it, and area magic deals reduced damage.

	Dependencies: EnemyBase, Navigator, MoverRig, TargetSelector, StateMachine, MathUtil,
	              CollisionGroup, CollisionGroups, Palette;
	              Registry: EnemyService, EffectService, PlayerService
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local CollisionGroup = require(Shared.Constants.CollisionGroup)
local MathUtil = require(Shared.Utilities.MathUtil)
local Palette = require(Shared.Data.Palette)
local StateMachine = require(Shared.Classes.StateMachine)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local CollisionGroups = require(Server.Systems.CollisionGroups)
local EnemyBase = require(script.Parent.EnemyBase)
local MoverRig = require(script.Parent.MoverRig)
local Navigator = require(script.Parent.Navigator)
local TargetSelector = require(script.Parent.TargetSelector)

local ZombieMole = setmetatable({}, { __index = EnemyBase })
ZombieMole.__index = ZombieMole

local TARGET_KINDS = { Kinds = { Crop = true, Core = true } }

function ZombieMole.new(match: any, definition: any, stats: any, spawnCFrame: CFrame, options: any?)
	local self = EnemyBase.new(match, definition, stats, spawnCFrame, options)
	return setmetatable(self, ZombieMole)
end

function ZombieMole:OnSpawned()
	local definition = self.Definition
	self.Navigator = self.Janitor:Add(Navigator.new(self, definition.Agent))
	self.Router = Services.EnemyService:GetUndergroundRouter(self.Match)
	self.Mover = self.Janitor:Add(MoverRig.new(self.Root :: BasePart))
	self.Route = {} :: { Vector3 }
	self.RouteIndex = 1
	self.ResurfacePoint = nil :: Vector3?
	self.DigEntryPoint = nil :: Vector3?
	self.CombatTarget = nil :: any
	self.LastCombatHitAt = 0
	self.Now = os.clock()
	self._hidden = {} :: { [BasePart]: number }
	self.Mound = nil :: BasePart?

	local humanoid = self.Humanoid :: Humanoid
	local root = self.Root :: BasePart
	self.SurfaceOffset = humanoid.HipHeight + root.Size.Y / 2

	self.Machine = self.Janitor:Add(self:_buildMachine())
	self.Machine:Start()
end

function ZombieMole:Think(now: number, dt: number)
	self.Now = now
	self.Machine:Update(dt)
end

-- Visibility / physics helpers ---------------------------------------------------------

function ZombieMole:_setBuried(buried: boolean)
	local model = self.Model
	local humanoid = self.Humanoid
	if model == nil or humanoid == nil then
		return
	end
	self.Underground = buried
	model:SetAttribute(Attributes.Underground, buried)
	humanoid.PlatformStand = buried
	CollisionGroups.SetModel(model, if buried then CollisionGroup.Ghost else CollisionGroup.Enemies)
	self.Mover:SetEnabled(buried)
	if not buried then
		self:_claimNetworkOwnership()
	end
end

function ZombieMole:_setHidden(hidden: boolean)
	local model = self.Model
	if model == nil then
		return
	end
	if hidden then
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") and descendant ~= self.Root and self._hidden[descendant] == nil then
				self._hidden[descendant] = descendant.Transparency
				descendant.Transparency = 1
			end
		end
		if self.Mound == nil then
			local root = self.Root :: BasePart
			local mound = Instance.new("Part")
			mound.Name = "DirtMound"
			mound.Shape = Enum.PartType.Ball
			mound.Size = Vector3.new(4, 2.2, 4)
			mound.Color = Palette.SoilWet
			mound.Material = Enum.Material.Ground
			mound.CanCollide = false
			mound.CanQuery = false
			mound.CanTouch = false
			mound.Massless = true
			mound.CollisionGroup = CollisionGroup.Ghost
			local weld = Instance.new("Weld")
			weld.Part0 = root
			weld.Part1 = mound
			weld.C0 = CFrame.new(0, self.Definition.DigDepth + 0.3, 0)
			weld.Parent = mound
			mound.Parent = model
			self.Mound = mound
		end
	else
		for part, transparency in self._hidden do
			if part.Parent then
				part.Transparency = transparency
			end
		end
		table.clear(self._hidden)
		if self.Mound then
			self.Mound:Destroy()
			self.Mound = nil
		end
	end
end

function ZombieMole:_floorY(): number
	return self.Match.Arena.FloorY
end

function ZombieMole:_undergroundSpeed(): number
	return self.Definition.UndergroundSpeed * self.SpeedMultiplier * Services.StatusEffectService:GetSpeedMultiplier(self)
end

-- A resurface point must be clear of defenses and other crops.
function ZombieMole:_isFree(point: Vector3): boolean
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = {
		self.Match.Folder:FindFirstChild("Defenses") :: Instance,
		self.Match.Core.Model,
	}
	local parts = Workspace:GetPartBoundsInBox(CFrame.new(point + Vector3.new(0, 2, 0)), Vector3.new(4, 4, 4), params)
	return #parts == 0
end

-- Plans a tunnel to the current target. Returns false when no valid route exists.
function ZombieMole:_planRoute(): boolean
	local target = self.Target
	if target == nil then
		return false
	end
	local resurface = self.Router:FindResurfacePoint(target:GetPosition(), function(point)
		return self:_isFree(point)
	end)
	if resurface == nil then
		return false
	end
	local route = self.Router:FindPath(self:GetPosition(), resurface)
	if route == nil or #route == 0 then
		return false
	end
	self.Route = route
	self.RouteIndex = 1
	self.ResurfacePoint = resurface
	return true
end

function ZombieMole:_targetInWalkRange(): boolean
	local target = self.Target
	return target ~= nil
		and MathUtil.FlatDistance(target:GetPosition(), self:GetPosition()) <= self.Definition.WalkRetargetDistance
end

function ZombieMole:OnDamaged(_amount: number, source: any)
	if self.Underground or source == nil or source.Player == nil then
		return
	end
	local session = Services.PlayerService:GetSession(source.Player)
	if session == nil or not session:IsAlive() then
		return
	end
	self.CombatTarget = session
	self.LastCombatHitAt = self.Now
	local state = self.Machine:GetState()
	if state == "AttackingCrop" or state == "Retargeting" then
		self.Machine:Transition("Combat")
	end
end

function ZombieMole:OnDeath(_killer: Player?)
	if self.Machine and not self.Machine:Is("Dying") then
		self.Machine:Transition("Dying")
	end
end

-- State machine ----------------------------------------------------------------------------

function ZombieMole:_buildMachine()
	local definition = self.Definition
	local states = {}

	states.Idle = {
		Update = function(machine)
			if machine:TimeInState() > 0.4 then
				machine:Transition("SelectingTarget")
			end
		end,
	}

	states.SelectingTarget = {
		Enter = function()
			self.Target = TargetSelector.Select(self, TARGET_KINDS)
			self.DigEntryPoint = nil
			if self.Target and not self.Router:IsDiggableAt(self:GetPosition()) then
				-- Standing on bedrock: walk to the nearest soil first.
				self.DigEntryPoint = self.Router:FindNearestDiggable(self:GetPosition(), 8)
			end
		end,
		Update = function(machine)
			local target = self.Target
			if target == nil or not target:IsAlive() then
				if machine:TimeInState() > 1 then
					machine:Transition("Retargeting")
				end
				return
			end
			if self:_targetInWalkRange() then
				machine:Transition("AttackingCrop")
				return
			end
			local entry = self.DigEntryPoint
			-- Walk to soil first; give up after a while and let the router snap the
			-- start to the nearest diggable cell instead.
			if entry and machine:TimeInState() < 8 then
				self.Navigator:SetGoal(entry, 2)
				if self.Navigator:Step(self.Now) ~= "Arrived" then
					return
				end
			end
			if self:_planRoute() then
				machine:Transition("EnteringUnderground")
			else
				-- No tunnel possible (target surrounded by bedrock): fight on the surface.
				machine:Transition("AttackingCrop")
			end
		end,
	}

	states.EnteringUnderground = {
		Enter = function()
			self.Navigator:Stop()
			local root = self.Root :: BasePart
			self:_setBuried(true)
			self.Mover:SetMaxSpeed(definition.DigDepth / definition.EnterDuration + 2)
			self.Mover:SetTarget(Vector3.new(root.Position.X, self:_floorY() - definition.DigDepth, root.Position.Z))
			Services.EffectService:PlayAt(self.Match, "DigIn", root.Position, {})
		end,
		Update = function(machine)
			if machine:TimeInState() >= definition.EnterDuration then
				self:_setHidden(true)
				machine:Transition("UndergroundTraversal")
			end
		end,
	}

	states.UndergroundTraversal = {
		Enter = function()
			self.TraversalDeadline = self.Now + 5 + (#self.Route * 12) / math.max(1, definition.UndergroundSpeed)
		end,
		Update = function(machine)
			local target = self.Target
			if target == nil or not target:IsAlive() then
				machine:Transition("Retargeting")
				return
			end
			local waypoint = self.Route[self.RouteIndex]
			if waypoint == nil or self.Now > self.TraversalDeadline then
				machine:Transition("Resurfacing")
				return
			end
			local buriedPoint = Vector3.new(waypoint.X, self:_floorY() - definition.DigDepth, waypoint.Z)
			self.Mover:SetMaxSpeed(self:_undergroundSpeed())
			self.Mover:SetTarget(buriedPoint, buriedPoint)
			if MathUtil.FlatDistance(self:GetPosition(), waypoint) <= 1.5 then
				self.RouteIndex += 1
			end
		end,
	}

	states.Resurfacing = {
		Enter = function()
			local point = self.ResurfacePoint or self:GetPosition()
			if not self:_isFree(point) and self.Target then
				point = self.Router:FindResurfacePoint(self.Target:GetPosition(), function(candidate)
					return self:_isFree(candidate)
				end) or point
			end
			local surface = Vector3.new(point.X, self:_floorY() + self.SurfaceOffset, point.Z)
			self.Mover:SetMaxSpeed(definition.DigDepth / definition.ResurfaceDuration + 6)
			self.Mover:SetTarget(surface, if self.Target then self.Target:GetPosition() else nil)
			self:_setHidden(false)
			Services.EffectService:PlayAt(self.Match, "DigOut", surface, {})
		end,
		Update = function(machine)
			if machine:TimeInState() >= definition.ResurfaceDuration then
				self:_setBuried(false)
				machine:Transition("AttackingCrop")
			end
		end,
	}

	states.AttackingCrop = {
		Update = function(machine)
			local target = self.Target
			if target == nil or not target:IsAlive() then
				machine:Transition("Retargeting")
				return
			end
			if self:AttackTarget(target, self.Now) then
				return
			end
			self.Navigator:SetGoal(TargetSelector.GetApproachPoint(self, target), (definition.AttackRange or 5) * 0.6)
			self.Navigator:Step(self.Now)
		end,
	}

	states.Combat = {
		Enter = function()
			self.Target = self.CombatTarget
		end,
		Update = function(machine)
			local foe = self.CombatTarget
			local timedOut = self.Now - self.LastCombatHitAt > definition.CombatTimeout
			if foe == nil or not TargetSelector.IsValid(self, foe) or timedOut then
				self.CombatTarget = nil
				machine:Transition("Retargeting")
				return
			end
			if self:AttackTarget(foe, self.Now) then
				return
			end
			self.Navigator:SetGoal(foe:GetPosition(), definition.AttackRange)
			self.Navigator:Step(self.Now)
		end,
	}

	states.Retargeting = {
		Enter = function()
			self.Target = TargetSelector.Select(self, TARGET_KINDS)
		end,
		Update = function(machine)
			local target = self.Target
			if target == nil or not target:IsAlive() then
				if machine:TimeInState() > 1 then
					self.Target = TargetSelector.Select(self, TARGET_KINDS)
					machine:Transition(if self.Underground then "Resurfacing" else "Idle")
				end
				return
			end
			if self.Underground then
				if self:_planRoute() then
					machine:Transition("UndergroundTraversal")
				else
					machine:Transition("Resurfacing")
				end
			elseif self:_targetInWalkRange() then
				machine:Transition("AttackingCrop")
			else
				machine:Transition("SelectingTarget")
			end
		end,
	}

	states.Dying = {
		Enter = function()
			-- Reset to a clean, visible, surface state so the corpse is readable even if
			-- the mole died underground.
			self.Route = {}
			self.CombatTarget = nil
			self.Target = nil
			if self.Underground then
				local position = self:GetPosition()
				local root = self.Root
				if root then
					root.CFrame = CFrame.new(position.X, self:_floorY() + self.SurfaceOffset, position.Z)
				end
			end
			self:_setHidden(false)
			self.Mover:SetEnabled(false)
			self.Underground = false
		end,
	}

	return StateMachine.new({
		Name = `ZombieMole_{self.Uid}`,
		Initial = "Idle",
		States = states,
		Transitions = {
			Idle = { "SelectingTarget" },
			SelectingTarget = { "EnteringUnderground", "AttackingCrop", "Retargeting" },
			EnteringUnderground = { "UndergroundTraversal" },
			UndergroundTraversal = { "Resurfacing", "Retargeting" },
			Resurfacing = { "AttackingCrop" },
			AttackingCrop = { "Retargeting", "Combat" },
			Combat = { "Retargeting" },
			Retargeting = { "UndergroundTraversal", "Resurfacing", "AttackingCrop", "SelectingTarget", "Idle", "Combat" },
			["*"] = { "Dying" },
		},
	})
end

return ZombieMole
