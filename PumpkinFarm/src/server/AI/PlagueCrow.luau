--!strict
--[[
	PlagueCrow
	Path: ServerScriptService.Server.AI.PlagueCrow

	Flying crop thief. Does not use PathfindingService (which is for walkers): it
	steers through the air with a MoverRig, keeping CruiseAltitude above the ground
	(downward raycast) and climbing over anything a forward raycast detects. Ground
	barricades are irrelevant to it.

		Retargeting -> Cruising -> Diving -> Stealing -> (Escaping | Retargeting)

	Stealing removes a stealable crop from the farm (CropService.StealCrop) and the crow
	flies to the nearest arena edge with it. Crops that cannot be carried (Anchored
	special) or the Great Pumpkin are pecked instead. Shooting a crow that carries a
	ripe crop recovers it into the Harvest Chest.

	Dependencies: EnemyBase, MoverRig, TargetSelector, StateMachine, MathUtil;
	              Registry: CropService, RewardService, EffectService, StatusEffectService
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local MathUtil = require(Shared.Utilities.MathUtil)
local StateMachine = require(Shared.Classes.StateMachine)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local EnemyBase = require(script.Parent.EnemyBase)
local MoverRig = require(script.Parent.MoverRig)
local TargetSelector = require(script.Parent.TargetSelector)

local PlagueCrow = setmetatable({}, { __index = EnemyBase })
PlagueCrow.__index = PlagueCrow

local TARGET_KINDS = { Kinds = { Crop = true, Core = true } }
local CLIMB_BOOST = 18
local CLIMB_TIME = 1.5

function PlagueCrow.new(match: any, definition: any, stats: any, spawnCFrame: CFrame, options: any?)
	local self = EnemyBase.new(match, definition, stats, spawnCFrame, options)
	return setmetatable(self, PlagueCrow)
end

function PlagueCrow:OnSpawned()
	self.Mover = self.Janitor:Add(MoverRig.new(self.Root :: BasePart))
	self.Mover:SetEnabled(true)
	self.Mover:SetTarget(self:GetPosition())
	self.Carrying = nil :: any
	self.Stolen = 0
	self.ClimbUntil = 0
	self.Now = os.clock()
	self.EscapePoint = nil :: Vector3?

	self._groundParams = RaycastParams.new()
	self._groundParams.FilterType = Enum.RaycastFilterType.Include
	self._groundParams.FilterDescendantsInstances = { self.Match.Arena.GroundFolder }
	self._obstacleParams = RaycastParams.new()
	self._obstacleParams.FilterType = Enum.RaycastFilterType.Include
	self._obstacleParams.FilterDescendantsInstances = { self.Match.Arena.PropsFolder, self.Match.Arena.GroundFolder }

	self.Machine = self.Janitor:Add(self:_buildMachine())
	self.Machine:Start()
end

function PlagueCrow:Think(now: number, dt: number)
	self.Now = now
	self.Mover:SetMaxSpeed(self:GetEffectiveSpeed())
	self.Machine:Update(dt)
end

function PlagueCrow:_groundHeightAt(position: Vector3): number
	local origin = Vector3.new(position.X, self.Match.Arena.FloorY + 100, position.Z)
	local result = Workspace:Raycast(origin, Vector3.new(0, -200, 0), self._groundParams)
	return if result then result.Position.Y else self.Match.Arena.FloorY
end

-- Flies toward `destination` at cruise altitude, climbing over obstacles ahead.
function PlagueCrow:_cruiseTo(destination: Vector3)
	local position = self:GetPosition()
	local direction = MathUtil.FlatDirection(position, destination)
	if direction.Magnitude > 0.5 then
		local ahead = Workspace:Raycast(position, direction * 18, self._obstacleParams)
		if ahead then
			self.ClimbUntil = self.Now + CLIMB_TIME
		end
	end
	local altitude = self:_groundHeightAt(position) + self.Definition.CruiseAltitude
	if self.Now < self.ClimbUntil then
		altitude += CLIMB_BOOST
	end
	local step = position + direction * math.min(12, MathUtil.FlatDistance(position, destination))
	self.Mover:SetTarget(Vector3.new(step.X, altitude, step.Z), destination)
end

function PlagueCrow:_nearestEdgePoint(): Vector3
	local bounds = self.Match.Arena.Bounds
	local position = self:GetPosition()
	local candidates = {
		Vector3.new(bounds.MinX, position.Y, position.Z),
		Vector3.new(bounds.MaxX, position.Y, position.Z),
		Vector3.new(position.X, position.Y, bounds.MinZ),
		Vector3.new(position.X, position.Y, bounds.MaxZ),
	}
	local best, bestDistance = candidates[1], math.huge
	for _, candidate in candidates do
		local distance = MathUtil.FlatDistance(position, candidate)
		if distance < bestDistance then
			best, bestDistance = candidate, distance
		end
	end
	return best
end

function PlagueCrow:_attachLoot(crop: any)
	local root = self.Root
	if root == nil then
		return
	end
	local loot = Instance.new("Part")
	loot.Name = "StolenCrop"
	loot.Shape = Enum.PartType.Ball
	loot.Size = Vector3.new(1.6, 1.6, 1.6)
	loot.Color = crop.Definition.Visual.Color
	loot.Material = Enum.Material.Neon
	loot.CanCollide = false
	loot.CanQuery = false
	loot.Massless = true
	local weld = Instance.new("Weld")
	weld.Part0 = root
	weld.Part1 = loot
	weld.C0 = CFrame.new(0, -1.4, 0)
	weld.Parent = loot
	loot.Parent = self.Model
end

function PlagueCrow:OnDeath(_killer: Player?)
	local carried = self.Carrying
	self.Carrying = nil
	if carried then
		Services.RewardService:OnStolenCropRecovered(self.Match, carried)
	end
	if self.Mover then
		self.Mover:SetEnabled(false)
	end
end

function PlagueCrow:_buildMachine()
	local definition = self.Definition
	local states = {}

	states.Retargeting = {
		Enter = function()
			self.Target = TargetSelector.Select(self, TARGET_KINDS)
		end,
		Update = function(machine)
			if self.Target and self.Target:IsAlive() then
				machine:Transition("Cruising")
			elseif machine:TimeInState() > 1 then
				self.Target = TargetSelector.Select(self, TARGET_KINDS)
				if self.Target == nil then
					-- Nothing left to raid: circle over the farm centre.
					self:_cruiseTo(self.Match.Arena.Center)
				end
			end
		end,
	}

	states.Cruising = {
		Update = function(machine)
			local target = self.Target
			if target == nil or not target:IsAlive() then
				machine:Transition("Retargeting")
				return
			end
			local destination = target:GetPosition()
			self:_cruiseTo(destination)
			if MathUtil.FlatDistance(self:GetPosition(), destination) <= 6 + TargetSelector.GetRadius(target) then
				machine:Transition("Diving")
			end
		end,
	}

	states.Diving = {
		Update = function(machine)
			local target = self.Target
			if target == nil or not target:IsAlive() then
				machine:Transition("Retargeting")
				return
			end
			local hover = target:GetPosition() + Vector3.new(0, 3 + TargetSelector.GetRadius(target), 0)
			self.Mover:SetMaxSpeed(self:GetEffectiveSpeed() * definition.DiveSpeedMultiplier)
			self.Mover:SetTarget(hover, target:GetPosition())
			if (self:GetPosition() - hover).Magnitude <= 3 then
				machine:Transition("Stealing")
			end
		end,
	}

	states.Stealing = {
		Update = function(machine)
			local target = self.Target
			if target == nil or not target:IsAlive() then
				machine:Transition("Retargeting")
				return
			end
			if target.Kind == "Crop" and target:CanBeStolen() then
				if machine:TimeInState() >= definition.StealDuration then
					if Services.CropService:StealCrop(target) then
						self.Carrying = target
						self.Stolen += 1
						self:_attachLoot(target)
						if self.Stolen >= definition.StealsBeforeEscape then
							machine:Transition("Escaping")
						else
							machine:Transition("Retargeting")
						end
					else
						machine:Transition("Retargeting")
					end
				end
				return
			end
			-- Too heavy to carry (or the Great Pumpkin): peck at it.
			self:AttackTarget(target, self.Now)
		end,
	}

	states.Escaping = {
		Enter = function()
			self.EscapePoint = self:_nearestEdgePoint()
		end,
		Update = function()
			local escape = self.EscapePoint :: Vector3
			self:_cruiseTo(escape)
			if MathUtil.FlatDistance(self:GetPosition(), escape) <= 8 then
				self.Carrying = nil
				self:Despawn("Escaped")
			end
		end,
	}

	states.Dying = {}

	return StateMachine.new({
		Name = `PlagueCrow_{self.Uid}`,
		Initial = "Retargeting",
		States = states,
		Transitions = {
			Retargeting = { "Cruising" },
			Cruising = { "Diving", "Retargeting" },
			Diving = { "Stealing", "Retargeting" },
			Stealing = { "Escaping", "Retargeting" },
			Escaping = {},
			["*"] = { "Dying" },
		},
	})
end

return PlagueCrow
