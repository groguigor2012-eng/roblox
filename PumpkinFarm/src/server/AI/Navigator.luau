--!strict
--[[
	Navigator
	Path: ServerScriptService.Server.AI.Navigator

	Ground navigation for Humanoid enemies. Separates "where am I going" (SetGoal) from
	"move one step" (Step, called from the enemy's AI tick), so the expensive part
	(PathfindingService) runs rarely and through PathQueue.

	Behaviour:
	  * short, unobstructed goals are walked directly (no path request)
	  * paths are recomputed only when the goal moved > RepathDistance, the agent is
	    stuck, or the previous path finished/failed (never more often than RepathInterval)
	  * barricades carry a PathfindingModifier (Label "Barricade", PassThrough) with a
	    high cost: enemies route around them when possible, and through them (attacking)
	    when the gate is sealed. GetBlockingDefense reports the defense in the way.
	  * failed path requests fall back to a direct MoveTo so enemies never freeze

	Dependencies: EnemyConfig, PathQueue, MathUtil; Registry: DefenseService

	API:
		Navigator.new(enemy, agent: { Radius, Height }) -> Navigator
		nav:SetGoal(position, stopDistance)
		nav:Step(now) -> "Idle" | "Moving" | "Arrived"
		nav:Stop()
		nav:IsStuck() -> boolean
		nav:GetBlockingDefense(probeDistance?) -> defense?
		nav:Destroy()
]]

local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local EnemyConfig = require(Shared.Config.EnemyConfig)
local MathUtil = require(Shared.Utilities.MathUtil)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local PathQueue = require(script.Parent.PathQueue)

local DIRECT_WALK_DISTANCE = 14
local WAYPOINT_REACHED = 3

local Navigator = {}
Navigator.__index = Navigator

function Navigator.new(enemy: any, agent: { Radius: number, Height: number })
	local self = setmetatable({}, Navigator)
	self.Enemy = enemy
	self.Path = PathfindingService:CreatePath({
		AgentRadius = agent.Radius,
		AgentHeight = agent.Height,
		AgentCanJump = true,
		AgentCanClimb = false,
		WaypointSpacing = 6,
		Costs = { Barricade = 25 },
	})
	self.Goal = nil :: Vector3?
	self.StopDistance = 2
	self.Waypoints = {} :: { PathWaypoint }
	self.WaypointIndex = 0
	self.PathGoal = nil :: Vector3?
	self.LastPathAt = -math.huge
	self.Computing = false
	self.Destroyed = false
	self.Stuck = false
	self._progressPosition = Vector3.zero
	self._progressAt = os.clock()

	self._obstacleParams = RaycastParams.new()
	self._obstacleParams.FilterType = Enum.RaycastFilterType.Include
	self._obstacleParams.FilterDescendantsInstances = {
		enemy.Match.Arena.MapFolder,
		enemy.Match.Folder:FindFirstChild("Defenses") :: Instance,
	}
	self._defenseParams = RaycastParams.new()
	self._defenseParams.FilterType = Enum.RaycastFilterType.Include
	self._defenseParams.FilterDescendantsInstances = { enemy.Match.Folder:FindFirstChild("Defenses") :: Instance }
	return self
end

function Navigator:SetGoal(position: Vector3, stopDistance: number)
	self.Goal = position
	self.StopDistance = stopDistance
end

function Navigator:Stop()
	self.Goal = nil
	self.Waypoints = {}
	self.WaypointIndex = 0
	local humanoid = self.Enemy.Humanoid
	local root = self.Enemy.Root
	if humanoid and root then
		humanoid:MoveTo(root.Position)
	end
end

function Navigator:IsStuck(): boolean
	return self.Stuck
end

function Navigator:_hasClearLine(from: Vector3, to: Vector3): boolean
	-- Probe horizontally at body height so the floor and low plots never count.
	local direction = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if direction.Magnitude < 0.5 then
		return true
	end
	local result = Workspace:Raycast(from + Vector3.new(0, 1, 0), direction, self._obstacleParams)
	return result == nil
end

function Navigator:_requestPath(from: Vector3, goal: Vector3, now: number)
	self.Computing = true
	self.LastPathAt = now
	self.PathGoal = goal
	PathQueue.Request(function()
		local ok = pcall(function()
			self.Path:ComputeAsync(from, goal)
		end)
		if self.Destroyed then
			return
		end
		self.Computing = false
		local status = self.Path.Status
		-- ClosestNoPath still yields waypoints toward the nearest reachable point,
		-- which beats walking straight into a fence.
		if ok and (status == Enum.PathStatus.Success or status == Enum.PathStatus.ClosestNoPath) then
			self.Waypoints = self.Path:GetWaypoints()
			self.WaypointIndex = math.min(2, #self.Waypoints)
		else
			-- No path: walk straight at the goal; barricade handling deals with walls.
			self.Waypoints = {}
			self.WaypointIndex = 0
		end
	end, function()
		local wanted = not self.Destroyed and self.Enemy:IsAlive()
		if not wanted then
			self.Computing = false
		end
		return wanted
	end)
end

function Navigator:_updateStuck(position: Vector3, now: number)
	if (position - self._progressPosition).Magnitude > EnemyConfig.StuckDistance then
		self._progressPosition = position
		self._progressAt = now
		self.Stuck = false
	elseif now - self._progressAt > EnemyConfig.StuckTime then
		self.Stuck = true
	end
end

function Navigator:Step(now: number): string
	local enemy = self.Enemy
	local humanoid: Humanoid? = enemy.Humanoid
	local root: BasePart? = enemy.Root
	local goal = self.Goal
	if humanoid == nil or root == nil or goal == nil then
		return "Idle"
	end
	local position = root.Position
	if MathUtil.FlatDistance(position, goal) <= self.StopDistance then
		humanoid:MoveTo(position)
		self.Stuck = false
		self._progressAt = now
		return "Arrived"
	end
	self:_updateStuck(position, now)

	local flatDistance = MathUtil.FlatDistance(position, goal)
	if flatDistance <= DIRECT_WALK_DISTANCE and not self.Stuck and self:_hasClearLine(position, goal) then
		humanoid:MoveTo(goal)
		return "Moving"
	end

	local goalMoved = self.PathGoal == nil or (self.PathGoal - goal).Magnitude > EnemyConfig.RepathDistance
	local exhausted = self.WaypointIndex == 0 or self.WaypointIndex > #self.Waypoints
	local canRepath = now - self.LastPathAt >= EnemyConfig.RepathInterval
	if not self.Computing and canRepath and (goalMoved or exhausted or self.Stuck) then
		self:_requestPath(position, goal, now)
	end

	if self.WaypointIndex >= 1 and self.WaypointIndex <= #self.Waypoints then
		local waypoint = self.Waypoints[self.WaypointIndex]
		if MathUtil.FlatDistance(position, waypoint.Position) <= WAYPOINT_REACHED then
			self.WaypointIndex += 1
			if self.WaypointIndex > #self.Waypoints then
				humanoid:MoveTo(goal)
				return "Moving"
			end
			waypoint = self.Waypoints[self.WaypointIndex]
		end
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
		end
		humanoid:MoveTo(waypoint.Position)
	else
		humanoid:MoveTo(goal)
	end
	return "Moving"
end

-- A barricade or sentry directly in front of the agent along its current heading.
function Navigator:GetBlockingDefense(probeDistance: number?): any
	local root: BasePart? = self.Enemy.Root
	if root == nil then
		return nil
	end
	local target = self.Goal
	if self.WaypointIndex >= 1 and self.WaypointIndex <= #self.Waypoints then
		target = self.Waypoints[self.WaypointIndex].Position
	end
	if target == nil then
		return nil
	end
	local direction = MathUtil.FlatDirection(root.Position, target)
	if direction.Magnitude < 0.5 then
		return nil
	end
	local distance = probeDistance or 6
	local result = Workspace:Raycast(root.Position, direction * distance, self._defenseParams)
	if result == nil then
		return nil
	end
	return Services.DefenseService:GetDefenseFromPart(self.Enemy.Match, result.Instance)
end

function Navigator:Destroy()
	self.Destroyed = true
	self.Waypoints = {}
	self.Path:Destroy()
end

return Navigator
