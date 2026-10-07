--!strict
--[[
	EscapeService
	Path: ServerScriptService.Server.Services.EscapeService

	Runs the Extraction decision: the Escape Door, each player's one-time choice, the
	payout, and the resolution that tells the Match what happens next.

	Rules:
	  * only players in the match, alive, within DoorRange of the door may decide
	  * each player decides exactly once (Decisions[userId]); repeats -> AlreadyDone
	  * ESCAPE pays immediately and returns the player to the lobby
	  * when everyone has decided, or the window expires:
	      - anyone chose CONTINUE -> undecided players continue with them -> "Continue"
	      - nobody chose CONTINUE -> undecided players are escaped (paid) -> "End"

	Escape steps (ProcessEscape), in order:
	   1. mark Paid[userId] BEFORE anything else (a duplicate can never pay twice)
	   2. freeze the payout from the server-owned chest (value x rate x risk bonus)
	   3. add Candies to the profile (CurrencyService -> CandyService -> DataService)
	   4. record statistics (RewardService.CommitMatchStats, escaped = true)
	   5. save the profile
	   6. strip match-only state (coins, weapon, effects, accessories)
	   7. return the player to the lobby (MatchService.RemoveSession)

	Dependencies: EscapeDoor, MatchConfig, Clock, Result, ResultCode, LifeState,
	              Format; Registry: PlayerService, MatchService, HarvestChestService,
	              CurrencyService, DifficultyService, RemoteService

	API:
		EscapeService:InitMatch(match) / CleanupMatch(match)
		EscapeService:OpenDoor(match)
		EscapeService:CloseDoor(match)
		EscapeService:SubmitDecision(player, decision) -> Result
		EscapeService:Update(match, deadlinePassed) -> "Continue" | "End" | nil
		EscapeService:GetSnapshot(match, player) -> ExtractionSnapshot
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local CurrencyId = require(Shared.Constants.CurrencyId)
local Format = require(Shared.Utilities.Format)
local LifeState = require(Shared.Constants.LifeState)
local MatchConfig = require(Shared.Config.MatchConfig)
local Result = require(Shared.Utilities.Result)
local ResultCode = require(Shared.Constants.ResultCode)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local EscapeDoor = require(Server.Classes.EscapeDoor)

type ExtractionState = {
	Open: boolean,
	Door: any,
	Decisions: { [number]: string },
	Paid: { [number]: boolean },
}

local EscapeService = {}

local states: { [any]: ExtractionState } = {}

function EscapeService:Init() end

function EscapeService:Start()
	Services.RemoteService:OnInvoke("RequestEscape", function(player: Player)
		return self:SubmitDecision(player, "Escape")
	end)
	Services.RemoteService:OnInvoke("RequestContinue", function(player: Player)
		return self:SubmitDecision(player, "Continue")
	end)
end

function EscapeService:InitMatch(match: any)
	states[match] = { Open = false, Door = nil, Decisions = {}, Paid = {} }
end

function EscapeService:CleanupMatch(match: any)
	local state = states[match]
	if state and state.Door then
		state.Door:Destroy()
	end
	states[match] = nil
end

function EscapeService:GetSnapshot(match: any, player: Player): any
	local state = states[match]
	if state == nil or not state.Open then
		return { Open = false }
	end
	local decisions = {}
	for userId, decision in state.Decisions do
		decisions[tostring(userId)] = decision
	end
	local nextLevel = match.ContinueLevel + 1
	return {
		Open = true,
		DeadlineAt = match.PhaseEndsAt,
		Decisions = decisions,
		YourDecision = state.Decisions[player.UserId],
		EstimatedCandies = Services.HarvestChestService:ComputePayout(match),
		NextContinueLevel = nextLevel,
		NextHealthMultiplier = Services.DifficultyService:GetDangerMultiplier(nextLevel),
		DoorPosition = state.Door and state.Door:GetPosition(),
	}
end

function EscapeService:_broadcast(match: any)
	for _, player in match:GetPlayers() do
		Services.RemoteService:FireClient("ExtractionUpdated", player, self:GetSnapshot(match, player))
	end
end

function EscapeService:OpenDoor(match: any)
	local state = states[match]
	if state == nil or state.Open then
		return
	end
	state.Open = true
	table.clear(state.Decisions)
	state.Door = EscapeDoor.new(match, match.Arena.DoorCFrame, function(player: Player, decision: string)
		local result = self:SubmitDecision(player, decision)
		if not result.Ok then
			Services.PlayerService:Notify(player, ResultCode.Messages[result.Code] or "You can't do that.", "Error")
		end
	end)
	local nextDanger = Services.DifficultyService:GetDangerMultiplier(match.ContinueLevel + 1)
	state.Door:SetPromptText(Services.HarvestChestService:ComputePayout(match), nextDanger)
	self:_broadcast(match)
	match:FireAll("MatchEvent", "ExtractionOpened", { DeadlineAt = match.PhaseEndsAt })
end

function EscapeService:CloseDoor(match: any)
	local state = states[match]
	if state == nil or not state.Open then
		return
	end
	state.Open = false
	if state.Door then
		state.Door:Destroy()
		state.Door = nil
	end
	self:_broadcast(match)
end

function EscapeService:SubmitDecision(player: Player, decision: string)
	if decision ~= "Escape" and decision ~= "Continue" then
		return Result.Fail(ResultCode.InvalidPayload)
	end
	local session = Services.PlayerService:GetSession(player)
	local match = session and session.Match
	if match == nil then
		return Result.Fail(ResultCode.NotInMatch)
	end
	local state = states[match]
	if state == nil or not state.Open then
		return Result.Fail(ResultCode.InvalidState)
	end
	if session.LifeState ~= LifeState.InMatch or not session:IsAlive() then
		return Result.Fail(ResultCode.Dead)
	end
	if state.Decisions[player.UserId] ~= nil or state.Paid[player.UserId] then
		return Result.Fail(ResultCode.AlreadyDone)
	end
	local position = session:GetPosition()
	if position == nil or state.Door == nil or (position - state.Door:GetPosition()).Magnitude > MatchConfig.Interaction.DoorRange then
		return Result.Fail(ResultCode.OutOfRange)
	end

	state.Decisions[player.UserId] = decision
	if decision == "Escape" then
		self:_processEscape(match, session)
	else
		match:Notify(`{player.DisplayName} chose to CONTINUE!`, "Warning")
	end
	self:_broadcast(match)
	return Result.Ok({ Decision = decision })
end

function EscapeService:_processEscape(match: any, session: any)
	local state = states[match]
	local player: Player = session.Player
	if state == nil or state.Paid[player.UserId] then
		return
	end
	state.Paid[player.UserId] = true
	state.Decisions[player.UserId] = "Escape"

	local payout = Services.HarvestChestService:ComputePayout(match)
	local paid = false
	if payout > 0 then
		paid = Services.CurrencyService:Grant(player, CurrencyId.Candies, payout, "Extraction")
		if not paid then
			warn(`[EscapeService] payout of {payout} to {player.UserId} failed (profile not loaded?)`)
		end
	end
	Services.MatchService:RemoveSession(session, "Escaped")

	local message = if paid
		then `You escaped with {Format.Commas(payout)} Candies!`
		else "You escaped! (The chest was empty, so no Candies this time.)"
	Services.PlayerService:Notify(player, message, "Success", 6)
	Services.RemoteService:FireClient("MatchEvent", player, "Escaped", { Candies = if paid then payout else 0, Wave = match.Wave })
	match:Notify(`{player.DisplayName} escaped to the lobby.`, "Info")
end

function EscapeService:Update(match: any, deadlinePassed: boolean): string?
	local state = states[match]
	if state == nil or not state.Open then
		return nil
	end
	local sessions = match:GetSessions()
	if #sessions == 0 then
		return "End"
	end

	local anyContinue = false
	local allDecided = true
	for _, session in sessions do
		local decision = state.Decisions[session.UserId]
		if decision == "Continue" then
			anyContinue = true
		elseif decision == nil then
			allDecided = false
		end
	end
	if not allDecided and not deadlinePassed then
		return nil
	end

	if anyContinue then
		for _, session in sessions do
			if state.Decisions[session.UserId] == nil then
				state.Decisions[session.UserId] = "Continue"
				Services.PlayerService:Notify(session.Player, "You stayed on the farm. Get ready!", "Warning")
			end
		end
		return "Continue"
	end

	-- Nobody chose to continue: escape everyone still here so their haul is banked.
	for _, session in sessions do
		if not state.Paid[session.UserId] then
			self:_processEscape(match, session)
		end
	end
	return "End"
end

return EscapeService
