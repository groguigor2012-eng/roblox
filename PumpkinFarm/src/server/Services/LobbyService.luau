--!strict
--[[
	LobbyService
	Path: ServerScriptService.Server.Services.LobbyService

	Builds the lobby, runs the matchmaking queue and hands groups of players to
	MatchService. Players join via the Farm Portal prompt or the Play button
	(RequestJoinQueue). When the first player queues, a countdown starts; the match
	launches when it expires or the queue reaches MaxPlayersPerMatch. Private servers
	need nothing special: everyone in the server shares one queue.

	Only players with a loaded profile may queue (a failed load must never earn or
	spend persistent currency).

	Dependencies: MapBuilder, MatchConfig, LifeState, Attributes, Clock, Result,
	              ResultCode; Registry: PlayerService, MatchService, DataService,
	              RemoteService

	API:
		LobbyService:GetSpawnCFrame() -> CFrame
		LobbyService:JoinQueue(player) -> Result
		LobbyService:LeaveQueue(player) -> Result
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local Clock = require(Shared.Utilities.Clock)
local LifeState = require(Shared.Constants.LifeState)
local MatchConfig = require(Shared.Config.MatchConfig)
local Result = require(Shared.Utilities.Result)
local ResultCode = require(Shared.Constants.ResultCode)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local MapBuilder = require(Server.Systems.MapBuilder)

local LobbyService = {}

local layout: any = nil
local queue: { Player } = {}
local queueEndsAt = 0

local function publishQueue()
	for _, player in queue do
		player:SetAttribute(Attributes.QueueEndsAt, queueEndsAt)
		player:SetAttribute(Attributes.QueueSize, #queue)
	end
end

local function clearQueueAttributes(player: Player)
	player:SetAttribute(Attributes.Queued, nil)
	player:SetAttribute(Attributes.QueueEndsAt, nil)
	player:SetAttribute(Attributes.QueueSize, nil)
end

function LobbyService:Init()
	layout = MapBuilder.BuildLobby(Workspace)
end

function LobbyService:Start()
	Services.RemoteService:OnInvoke("RequestJoinQueue", function(player: Player)
		return self:JoinQueue(player)
	end)
	Services.RemoteService:OnInvoke("RequestLeaveQueue", function(player: Player)
		return self:LeaveQueue(player)
	end)
	layout.PortalPrompt.Triggered:Connect(function(player: Player)
		local session = Services.PlayerService:GetSession(player)
		if session and session.LifeState == LifeState.Queued then
			self:LeaveQueue(player)
			return
		end
		local result = self:JoinQueue(player)
		if not result.Ok then
			Services.PlayerService:Notify(player, ResultCode.Messages[result.Code] or "Can't join right now.", "Error")
		end
	end)

	task.spawn(function()
		while true do
			task.wait(0.5)
			self:_tick()
		end
	end)
end

function LobbyService:GetSpawnCFrame(): CFrame
	return layout.SpawnCFrame
end

function LobbyService:JoinQueue(player: Player)
	local session = Services.PlayerService:GetSession(player)
	if session == nil then
		return Result.Fail(ResultCode.NotAllowed)
	end
	if not Services.DataService:IsLoaded(player) then
		return Result.Fail(ResultCode.DataNotLoaded)
	end
	if session.Match ~= nil then
		return Result.Fail(ResultCode.AlreadyInMatch)
	end
	if table.find(queue, player) then
		return Result.Fail(ResultCode.AlreadyDone)
	end
	if session.LifeState ~= LifeState.Lobby then
		return Result.Fail(ResultCode.InvalidState)
	end
	table.insert(queue, player)
	session:SetLifeState(LifeState.Queued)
	player:SetAttribute(Attributes.Queued, true)
	if #queue == 1 then
		queueEndsAt = Clock.Now() + MatchConfig.QueueCountdown
	end
	publishQueue()
	return Result.Ok({ QueueSize = #queue, StartsAt = queueEndsAt })
end

function LobbyService:LeaveQueue(player: Player)
	local index = table.find(queue, player)
	if index == nil then
		return Result.Fail(ResultCode.NotFound)
	end
	table.remove(queue, index)
	clearQueueAttributes(player)
	local session = Services.PlayerService:GetSession(player)
	if session and session.LifeState == LifeState.Queued then
		session:SetLifeState(LifeState.Lobby)
	end
	publishQueue()
	return Result.Ok()
end

function LobbyService:_tick()
	-- Drop anyone who stopped being eligible (left, data released, already in a match).
	for index = #queue, 1, -1 do
		local player = queue[index]
		local session = Services.PlayerService:GetSession(player)
		if session == nil or session.Match ~= nil or session.LifeState ~= LifeState.Queued then
			table.remove(queue, index)
			clearQueueAttributes(player)
		end
	end
	if #queue == 0 then
		return
	end
	local full = #queue >= MatchConfig.MaxPlayersPerMatch
	if not full and Clock.Now() < queueEndsAt then
		return
	end
	if not Services.MatchService:CanCreateMatch() then
		-- All arenas busy: keep the queue and retry shortly.
		queueEndsAt = Clock.Now() + 5
		publishQueue()
		for _, player in queue do
			Services.PlayerService:Notify(player, ResultCode.Messages.QueueFull, "Warning")
		end
		return
	end

	local group = {}
	for _ = 1, math.min(#queue, MatchConfig.MaxPlayersPerMatch) do
		local player = table.remove(queue, 1) :: Player
		clearQueueAttributes(player)
		table.insert(group, Services.PlayerService:GetSession(player))
	end
	local match = Services.MatchService:CreateMatch(group)
	if match == nil then
		for _, session in group do
			session:SetLifeState(LifeState.Lobby)
			Services.PlayerService:Notify(session.Player, ResultCode.Messages.ServerError, "Error")
		end
	end
	if #queue > 0 then
		queueEndsAt = Clock.Now() + MatchConfig.QueueCountdown
		publishQueue()
	end
end

return LobbyService
