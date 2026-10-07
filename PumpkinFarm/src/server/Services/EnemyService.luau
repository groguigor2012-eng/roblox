--!strict
--[[
	EnemyService
	Path: ServerScriptService.Server.Services.EnemyService

	Registry and factory for enemies. Every enemy of every match is tracked here (per
	match), driven by one AIScheduler, and queried spatially from the registry instead of
	workspace scans. It is also the only place that turns an enemy death into rewards.

	Spawning: definition -> DifficultyService stats (wave, players, Continue level) ->
	AI class from EnemyConfig.Class (ServerScriptService.Server.AI.<Class>) -> model.

	Dependencies: EnemyConfig, AIScheduler, UndergroundRouter, ProjectileSystem, Signal;
	              Registry: DifficultyService, RewardService

	API:
		EnemyService:InitMatch(match) / CleanupMatch(match)
		EnemyService:SpawnEnemy(match, enemyId, cframe, options?) -> enemy?
		EnemyService:GetEnemies(match) -> { enemy }
		EnemyService:GetAliveCount(match) -> number
		EnemyService:GetEnemiesInRadius(match, position, radius, filter?) -> { enemy }
		EnemyService:GetNearestEnemy(match, position, range, filter?) -> enemy?
		EnemyService:GetUndergroundRouter(match) -> UndergroundRouter
		EnemyService:DespawnAll(match, reason)
		EnemyService:KillAll(match)                      -- debug helper
		EnemyService:SweepOrphans(match) -> number
		EnemyService:Schedule(enemy) / Unschedule(enemy)
		EnemyService.EnemyRemoved : Signal(match, enemy, reason)   -- "Killed" or a despawn reason
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local EnemyConfig = require(Shared.Config.EnemyConfig)
local Signal = require(Shared.Classes.Signal)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local AIScheduler = require(Server.Systems.AIScheduler)
local ProjectileSystem = require(Server.Systems.ProjectileSystem)
local UndergroundRouter = require(Server.AI.UndergroundRouter)

type MatchEnemies = {
	Enemies: { [string]: any },
	Count: number,
	Router: any,
}

local MAX_AI_UPDATES_PER_FRAME = 40

local EnemyService = {}
EnemyService.EnemyRemoved = Signal.new()

local states: { [any]: MatchEnemies } = {}
local scheduler = AIScheduler.new(MAX_AI_UPDATES_PER_FRAME)
local classModules: { [string]: any } = {}

local function loadClass(className: string): any
	local cached = classModules[className]
	if cached then
		return cached
	end
	local moduleScript = Server.AI:FindFirstChild(className)
	if moduleScript == nil or not moduleScript:IsA("ModuleScript") then
		warn(`[EnemyService] AI class {className} not found`)
		return nil
	end
	local module = (require :: any)(moduleScript)
	classModules[className] = module
	return module
end

function EnemyService:Init() end

function EnemyService:Start()
	scheduler:Start()
	ProjectileSystem.Start()
end

function EnemyService:Schedule(enemy: any)
	scheduler:Add(enemy)
end

function EnemyService:Unschedule(enemy: any)
	scheduler:Remove(enemy)
end

function EnemyService:InitMatch(match: any)
	states[match] = { Enemies = {}, Count = 0, Router = nil }
end

function EnemyService:CleanupMatch(match: any)
	ProjectileSystem.CancelMatch(match)
	local state = states[match]
	if state == nil then
		return
	end
	states[match] = nil
	for _, enemy in state.Enemies do
		enemy:Destroy()
	end
end

local function unregister(match: any, enemy: any, reason: string)
	local state = states[match]
	if state and state.Enemies[enemy.Uid] == enemy then
		state.Enemies[enemy.Uid] = nil
		state.Count -= 1
		EnemyService.EnemyRemoved:Fire(match, enemy, reason)
	end
end

function EnemyService:SpawnEnemy(match: any, enemyId: string, cframe: CFrame, options: any?): any
	local state = states[match]
	local definition = EnemyConfig.Get(enemyId)
	if state == nil or definition == nil then
		warn(`[EnemyService] cannot spawn {enemyId} (match state or definition missing)`)
		return nil
	end
	local class = loadClass(definition.Class)
	if class == nil then
		return nil
	end
	local stats = Services.DifficultyService:GetEnemyStats(enemyId, match:GetContext())
	local enemy = class.new(match, definition, stats, cframe, options)

	local ok, spawnedOrError = pcall(enemy.Spawn, enemy)
	if not ok or spawnedOrError ~= true then
		warn(`[EnemyService] spawn of {enemyId} failed: {spawnedOrError}`)
		enemy:Destroy()
		return nil
	end

	state.Enemies[enemy.Uid] = enemy
	state.Count += 1
	enemy.Died:Connect(function(dead: any, killer: Player?)
		unregister(match, dead, "Killed")
		Services.RewardService:OnEnemyKilled(match, dead, killer, dead.Contributions)
	end)
	enemy.Removed:Connect(function(removed: any, reason: string)
		unregister(match, removed, reason)
	end)
	enemy:Start()
	return enemy
end

function EnemyService:GetEnemies(match: any): { any }
	local list = {}
	local state = states[match]
	if state then
		for _, enemy in state.Enemies do
			table.insert(list, enemy)
		end
	end
	return list
end

function EnemyService:GetAliveCount(match: any): number
	local state = states[match]
	return if state then state.Count else 0
end

function EnemyService:GetEnemiesInRadius(match: any, position: Vector3, radius: number, filter: ((any) -> boolean)?): { any }
	local list = {}
	local state = states[match]
	if state == nil then
		return list
	end
	for _, enemy in state.Enemies do
		if enemy:IsAlive() then
			local reach = radius + (enemy.HitRadius or 0)
			if (enemy:GetPosition() - position).Magnitude <= reach and (filter == nil or filter(enemy)) then
				table.insert(list, enemy)
			end
		end
	end
	return list
end

function EnemyService:GetNearestEnemy(match: any, position: Vector3, range: number, filter: ((any) -> boolean)?): any
	local best, bestDistance = nil, range
	local state = states[match]
	if state == nil then
		return nil
	end
	for _, enemy in state.Enemies do
		if enemy:IsAlive() and (filter == nil or filter(enemy)) then
			local distance = (enemy:GetPosition() - position).Magnitude
			if distance <= bestDistance then
				best, bestDistance = enemy, distance
			end
		end
	end
	return best
end

function EnemyService:GetUndergroundRouter(match: any): any
	local state = states[match]
	assert(state, "[EnemyService] router requested for an unknown match")
	if state.Router == nil then
		local mole = EnemyConfig.Get("ZombieMole")
		state.Router = UndergroundRouter.ForArena(
			match.Arena,
			mole and mole.GridCellSize or 4,
			mole and mole.MaxRouteExpansions or 6000
		)
	end
	return state.Router
end

function EnemyService:DespawnAll(match: any, reason: string)
	for _, enemy in self:GetEnemies(match) do
		enemy:Despawn(reason)
	end
end

function EnemyService:KillAll(match: any)
	for _, enemy in self:GetEnemies(match) do
		if enemy:IsAlive() then
			enemy:Die(nil)
		end
	end
end

-- Removes registered enemies whose model vanished and models nobody owns.
function EnemyService:SweepOrphans(match: any): number
	local removed = 0
	local state = states[match]
	if state == nil then
		return 0
	end
	for _, enemy in self:GetEnemies(match) do
		local model = enemy.Model
		if enemy:IsAlive() and (model == nil or model.Parent == nil) then
			enemy:Despawn("Orphaned")
			removed += 1
		end
	end
	local folder = match.Folder:FindFirstChild("Enemies")
	if folder then
		for _, model in folder:GetChildren() do
			local uid = model:GetAttribute(Attributes.EnemyUid)
			local health = model:GetAttribute(Attributes.Health)
			-- Corpses (Health 0) are owned by Debris and expire on their own.
			if (uid == nil or state.Enemies[uid] == nil) and health ~= 0 then
				model:Destroy()
				removed += 1
			end
		end
	end
	return removed
end

return EnemyService
