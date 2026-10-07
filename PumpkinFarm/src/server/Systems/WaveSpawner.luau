--!strict
--[[
	WaveSpawner
	Path: ServerScriptService.Server.Systems.WaveSpawner

	Releases a wave plan into the arena over time. Each step it waits for the spawn
	interval and for the match to be below WaveConfig.MaxAliveEnemies, then spawns a
	burst at the grave spawn points (random offset; flying enemies spawn high; the boss
	spawns at the point farthest from the players).

	Dependencies: WaveConfig, EnemyConfig; Registry: EnemyService

	API:
		WaveSpawner.new(match, plan) -> WaveSpawner
		spawner:Step(now)
		spawner:IsFinished() -> boolean
		spawner:GetRemaining() -> number
		spawner:SkipRemaining()
		spawner:Destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local EnemyConfig = require(Shared.Config.EnemyConfig)
local WaveConfig = require(Shared.Config.WaveConfig)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)

local WaveSpawner = {}
WaveSpawner.__index = WaveSpawner

function WaveSpawner.new(match: any, plan: any)
	return setmetatable({
		Match = match,
		Plan = plan,
		Index = 1,
		NextSpawnAt = 0,
		Destroyed = false,
	}, WaveSpawner)
end

function WaveSpawner:IsFinished(): boolean
	return self.Index > #self.Plan.Entries
end

function WaveSpawner:GetRemaining(): number
	return math.max(0, #self.Plan.Entries - self.Index + 1)
end

function WaveSpawner:SkipRemaining()
	self.Index = #self.Plan.Entries + 1
end

function WaveSpawner:_spawnPoint(enemyId: string): CFrame
	local match = self.Match
	local arena = match.Arena
	local spawns = arena.EnemySpawns
	local point = spawns[match.Rng:NextInteger(1, #spawns)]
	local definition = EnemyConfig.Get(enemyId)

	if definition and definition.IsBoss then
		-- Farthest spawn from the living players gives the team time to react.
		local best, bestDistance = point, -1
		for _, candidate in spawns do
			local nearest = math.huge
			for _, session in match:GetLivingSessions() do
				local position = session:GetPosition()
				if position then
					nearest = math.min(nearest, (position - candidate).Magnitude)
				end
			end
			if nearest > bestDistance then
				best, bestDistance = candidate, nearest
			end
		end
		point = best
	end

	local offset = Vector3.new(match.Rng:NextNumber(-6, 6), 0, match.Rng:NextNumber(-6, 6))
	local height = 4
	if definition and definition.MovementType == "Air" then
		height = WaveConfig.AirSpawnHeight
	elseif definition and definition.IsBoss then
		height = 10
	end
	local position = point + offset + Vector3.new(0, height, 0)
	return CFrame.lookAt(position, Vector3.new(arena.Center.X, position.Y, arena.Center.Z))
end

function WaveSpawner:Step(now: number)
	if self.Destroyed or self:IsFinished() or now < self.NextSpawnAt then
		return
	end
	local match = self.Match
	local alive = Services.EnemyService:GetAliveCount(match)
	if alive >= WaveConfig.MaxAliveEnemies then
		return
	end
	local burst = math.min(self.Plan.BurstSize, WaveConfig.MaxAliveEnemies - alive)
	for _ = 1, burst do
		if self:IsFinished() then
			break
		end
		local enemyId = self.Plan.Entries[self.Index]
		self.Index += 1
		Services.EnemyService:SpawnEnemy(match, enemyId, self:_spawnPoint(enemyId), { IsWaveEnemy = true })
	end
	self.NextSpawnAt = now + self.Plan.SpawnInterval
end

function WaveSpawner:Destroy()
	self.Destroyed = true
end

return WaveSpawner
