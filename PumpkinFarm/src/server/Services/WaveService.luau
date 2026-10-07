--!strict
--[[
	WaveService
	Path: ServerScriptService.Server.Services.WaveService

	Per-match wave orchestration. The Match state machine calls:
		PrepareWave  (PreparingWave)  -> compose the deterministic plan
		StartWave    (WaveActive / BossWave) -> start the spawner
		Update       (every match tick) -> spawn, publish "EnemiesRemaining"
		IsWaveCleared -> spawner done AND no enemy alive (minions included)
		StopWave     (MatchEnding) -> stop spawning, despawn everything

	Dependencies: WaveComposer, WaveSpawner, Attributes;
	              Registry: DifficultyService, EnemyService

	API:
		WaveService:InitMatch(match) / CleanupMatch(match)
		WaveService:PrepareWave(match) -> Plan
		WaveService:StartWave(match)
		WaveService:Update(match, dt)
		WaveService:IsWaveCleared(match) -> boolean
		WaveService:GetRemaining(match) -> number
		WaveService:StopWave(match)
		WaveService:ForceComplete(match)         -- debug
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Constants.Attributes)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local WaveComposer = require(Server.Systems.WaveComposer)
local WaveSpawner = require(Server.Systems.WaveSpawner)

type WaveState = { Plan: any, Spawner: any, Active: boolean, Published: number }

local WaveService = {}

local states: { [any]: WaveState } = {}

function WaveService:Init() end

function WaveService:InitMatch(match: any)
	states[match] = { Plan = nil, Spawner = nil, Active = false, Published = -1 }
	match:SetAttribute(Attributes.EnemiesRemaining, 0)
end

function WaveService:CleanupMatch(match: any)
	local state = states[match]
	if state and state.Spawner then
		state.Spawner:Destroy()
	end
	states[match] = nil
end

function WaveService:GetRemaining(match: any): number
	local state = states[match]
	if state == nil then
		return 0
	end
	local toSpawn = 0
	if state.Spawner then
		toSpawn = state.Spawner:GetRemaining()
	elseif state.Plan then
		toSpawn = #state.Plan.Entries
	end
	return toSpawn + Services.EnemyService:GetAliveCount(match)
end

function WaveService:_publish(match: any)
	local state = states[match]
	local remaining = self:GetRemaining(match)
	if state and remaining ~= state.Published then
		state.Published = remaining
		match:SetAttribute(Attributes.EnemiesRemaining, remaining)
	end
end

function WaveService:PrepareWave(match: any): any
	local state = states[match]
	assert(state, "[WaveService] match not initialised")
	if state.Spawner then
		state.Spawner:Destroy()
		state.Spawner = nil
	end
	state.Plan = WaveComposer.Compose(match.Wave, match:GetContext(), match.Rng, Services.DifficultyService)
	state.Active = false
	self:_publish(match)
	return state.Plan
end

function WaveService:StartWave(match: any)
	local state = states[match]
	if state == nil then
		return
	end
	if state.Plan == nil then
		self:PrepareWave(match)
	end
	state.Spawner = WaveSpawner.new(match, state.Plan)
	state.Active = true
	self:_publish(match)
end

function WaveService:Update(match: any, _dt: number)
	local state = states[match]
	if state == nil or not state.Active or state.Spawner == nil then
		return
	end
	state.Spawner:Step(os.clock())
	self:_publish(match)
end

function WaveService:IsWaveCleared(match: any): boolean
	local state = states[match]
	if state == nil or not state.Active or state.Spawner == nil then
		return false
	end
	local cleared = state.Spawner:IsFinished() and Services.EnemyService:GetAliveCount(match) == 0
	if cleared then
		state.Active = false
		state.Plan = nil
		self:_publish(match)
	end
	return cleared
end

function WaveService:StopWave(match: any)
	local state = states[match]
	if state == nil then
		return
	end
	state.Active = false
	if state.Spawner then
		state.Spawner:Destroy()
		state.Spawner = nil
	end
	state.Plan = nil
	Services.EnemyService:DespawnAll(match, "WaveStopped")
	self:_publish(match)
end

function WaveService:ForceComplete(match: any)
	local state = states[match]
	if state and state.Spawner then
		state.Spawner:SkipRemaining()
	end
	Services.EnemyService:KillAll(match)
end

return WaveService
