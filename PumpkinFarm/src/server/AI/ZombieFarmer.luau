--!strict
--[[
	ZombieFarmer
	Path: ServerScriptService.Server.AI.ZombieFarmer

	Grunt (and its Witch-summoned mini variant "ZombieFarmerMini", same class).
	Behaviour each think:
		1. acquire/refresh a target (crops > players in aggro range > sentries > core)
		2. attack it when within reach
		3. if a barricade/sentry blocks the way, attack that instead
		4. otherwise path toward the target

	Dependencies: EnemyBase, Navigator, TargetSelector
]]

local EnemyBase = require(script.Parent.EnemyBase)
local Navigator = require(script.Parent.Navigator)
local TargetSelector = require(script.Parent.TargetSelector)

local ZombieFarmer = setmetatable({}, { __index = EnemyBase })
ZombieFarmer.__index = ZombieFarmer

function ZombieFarmer.new(match: any, definition: any, stats: any, spawnCFrame: CFrame, options: any?)
	local self = EnemyBase.new(match, definition, stats, spawnCFrame, options)
	return setmetatable(self, ZombieFarmer)
end

function ZombieFarmer:OnSpawned()
	self.Navigator = self.Janitor:Add(Navigator.new(self, self.Definition.Agent))
end

function ZombieFarmer:Think(now: number, _dt: number)
	local target = self:RefreshTarget(now)
	if target == nil then
		self.Navigator:Stop()
		return
	end
	if self:AttackTarget(target, now) then
		return
	end

	local blocking = self.Navigator:GetBlockingDefense()
	if blocking and blocking:IsAlive() then
		self:AttackTarget(blocking, now)
		return
	end

	-- Stop well inside attack reach (reach also includes the target and body radii).
	self.Navigator:SetGoal(TargetSelector.GetApproachPoint(self, target), (self.Definition.AttackRange or 5) * 0.6)
	self.Navigator:Step(now)
end

return ZombieFarmer
