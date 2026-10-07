--!strict
--[[
	MatchService
	Path: ServerScriptService.Server.Services.MatchService

	Creates, drives and destroys Match instances. Responsibilities:
	  * arena slot allocation (MatchConfig.MaxConcurrentMatches arenas per server)
	  * per-match service initialisation in a fixed order (MATCH_SERVICES) and teardown
	    in reverse order through CleanupService
	  * one central update loop for every match at MatchConfig.UpdateRate
	  * moving players out of a match (escape, disconnect) and back to the lobby

	Multi-server note: CreateMatch(sessions) is the single entry point. A dedicated
	match place would call it from PlayerAdded with the party from TeleportData; nothing
	else in the match code assumes the lobby lives in the same server.

	Dependencies: Match, MatchConfig, LifeState; Registry: PlayerService, CleanupService,
	              RewardService, MatchCoinService, WeaponService, StatusEffectService,
	              and every service in MATCH_SERVICES

	API:
		MatchService:CanCreateMatch() -> boolean
		MatchService:CreateMatch(sessions) -> Match?
		MatchService:GetMatch(matchId) -> Match?
		MatchService:GetMatches() -> { Match }
		MatchService:GetMatchForPlayer(player) -> Match?
		MatchService:RemoveSession(session, reason)    -- "Escaped" | "Left"
		MatchService:OnPlayerRemoving(session)
		MatchService:DestroyMatch(match)
		MatchService.MatchServices : { string }        -- init order
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local LifeState = require(Shared.Constants.LifeState)
local MatchConfig = require(Shared.Config.MatchConfig)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local Match = require(Server.Classes.Match)

local MatchService = {}

-- Services that hold per-match state. InitMatch runs in this order, CleanupMatch in
-- reverse, so e.g. enemies are removed before the crops and defenses they target.
MatchService.MatchServices = {
	"CropService",
	"SeedShopService",
	"HarvestChestService",
	"BarricadeService",
	"SentryService",
	"DefenseService",
	"EnemyService",
	"WaveService",
	"EscapeService",
}

local matches: { [number]: any } = {}
local arenaSlots: { [number]: number } = {} -- [arenaIndex] = matchId
local nextMatchId = 0

function MatchService:Init() end

function MatchService:Start()
	local step = 1 / MatchConfig.UpdateRate
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < step then
			return
		end
		local elapsed = accumulator
		accumulator = 0
		for _, match in matches do
			local ok, err = xpcall(match.Update, debug.traceback, match, elapsed)
			if not ok then
				warn(`[MatchService] match {match.Id} update error: {err}`)
			end
		end
	end)
end

function MatchService:_freeArena(): number?
	for index = 1, MatchConfig.MaxConcurrentMatches do
		if arenaSlots[index] == nil then
			return index
		end
	end
	return nil
end

function MatchService:CanCreateMatch(): boolean
	return self:_freeArena() ~= nil
end

function MatchService:CreateMatch(sessions: { any }): any
	local arenaIndex = self:_freeArena()
	if arenaIndex == nil or #sessions == 0 then
		return nil
	end
	nextMatchId += 1
	local matchId = nextMatchId
	arenaSlots[arenaIndex] = matchId

	local origin = MatchConfig.Arena.Origin + Vector3.new(MatchConfig.Arena.Spacing * (arenaIndex - 1), 0, 0)
	local ok, matchOrError = pcall(Match.new, matchId, arenaIndex, origin, sessions)
	if not ok then
		warn(`[MatchService] failed to build match {matchId}: {matchOrError}`)
		arenaSlots[arenaIndex] = nil
		-- Match.new may have attached sessions before failing; detach them again.
		for _, session in sessions do
			session:ResetMatchState()
		end
		return nil
	end
	local match = matchOrError
	matches[matchId] = match

	for _, serviceName in self.MatchServices do
		local service = Services[serviceName]
		local initOk, err = xpcall(service.InitMatch, debug.traceback, service, match)
		if not initOk then
			warn(`[MatchService] {serviceName}:InitMatch failed for match {matchId}: {err}`)
		end
	end

	for _, session in sessions do
		session:SetLifeState(LifeState.InMatch)
	end
	match:Start()
	return match
end

function MatchService:GetMatch(matchId: number): any
	return matches[matchId]
end

function MatchService:GetMatches(): { any }
	local list = {}
	for _, match in matches do
		table.insert(list, match)
	end
	return list
end

function MatchService:GetMatchForPlayer(player: Player): any
	local session = Services.PlayerService:GetSession(player)
	return session and session.Match
end

-- Strips match-only state from a session (coins, weapon, effects, accessories).
local function detach(session: any, match: any)
	match:DetachSession(session)
	Services.MatchCoinService:Clear(session.Player)
	Services.WeaponService:UnequipWeapon(session)
	Services.StatusEffectService:ClearTarget(session)
	session:ResetMatchState()
end

function MatchService:RemoveSession(session: any, reason: string)
	local match = session.Match
	if match == nil then
		return
	end
	Services.RewardService:CommitMatchStats(session, match, reason == "Escaped")
	detach(session, match)
	if reason ~= "Left" and not session.Destroyed then
		session:SetLifeState(LifeState.Lobby)
		task.spawn(function()
			Services.PlayerService:SpawnInLobby(session)
		end)
	end
end

function MatchService:OnPlayerRemoving(session: any)
	if session.Match then
		self:RemoveSession(session, "Left")
	end
end

function MatchService:DestroyMatch(match: any)
	if matches[match.Id] ~= match then
		return
	end
	-- Anyone still inside (match ended normally) goes back to the lobby first.
	for _, session in match:GetSessions() do
		self:RemoveSession(session, "Returned")
	end
	Services.CleanupService:CleanupMatch(match, self.MatchServices)
	matches[match.Id] = nil
	if arenaSlots[match.ArenaIndex] == match.Id then
		arenaSlots[match.ArenaIndex] = nil
	end
end

return MatchService
