--!strict
--[[
	Match
	Path: ServerScriptService.Server.Classes.Match

	One isolated match instance. ALL mutable match state hangs off this object (or off
	per-match state that services key by this object), so several matches can run in
	the same server without sharing anything. The lifecycle is a StateMachine:

		Waiting -> Starting -> Intermission -> PreparingWave -> WaveActive | BossWave
		-> WaveComplete -> (Intermission | Extraction)
		Extraction -> ContinuePreparation -> PreparingWave ...   (players chose Continue)
		Extraction -> MatchEnding                                (everyone escaped)
		any state  -> MatchEnding (farm lost / team wiped / abandoned) -> Cleanup

	Replicated state lives as attributes on the match folder (workspace.Matches.Match_<id>)
	so clients count down locally from PhaseEndsAt instead of receiving timer ticks.

	Dependencies: StateMachine, Janitor, MatchState, LifeState, Attributes, MatchConfig,
	              Clock, MapBuilder, FarmCore; Registry: PlayerService, WaveService,
	              SeedShopService, SeedService, MatchCoinService, UpgradeService,
	              RewardService, EscapeService, CropService, DefenseService,
	              HarvestChestService, DifficultyService, RemoteService, MatchService

	API:
		Match.new(id, arenaIndex, origin, sessions) -> Match
		match:Start()
		match:Update(dt)
		match:GetPlayers() -> { Player }
		match:GetSessions() -> { PlayerSession }
		match:GetLivingSessions() -> { PlayerSession }
		match:GetPlayerCount() -> number
		match:GetContext() -> { Wave, ContinueLevel, PlayerCount }
		match:GetState() -> string
		match:IsCombatState() -> boolean
		match:SetAttribute(name, value)
		match:SetPhaseDuration(seconds?)
		match:Notify(text, kind?, duration?)
		match:FireAll(remoteName, ...)
		match:OnPlayerDowned(session)
		match:DetachSession(session)
		match:RequestEnd(reason)
		match:Destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local Clock = require(Shared.Utilities.Clock)
local DifficultyConfig = require(Shared.Config.DifficultyConfig)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local Format = require(Shared.Utilities.Format)
local Janitor = require(Shared.Classes.Janitor)
local LifeState = require(Shared.Constants.LifeState)
local MatchConfig = require(Shared.Config.MatchConfig)
local MatchState = require(Shared.Constants.MatchState)
local StateMachine = require(Shared.Classes.StateMachine)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local FarmCore = require(Server.Classes.FarmCore)
local MapBuilder = require(Server.Systems.MapBuilder)

local Match = {}
Match.__index = Match

local LOSS_REASONS = { FarmLost = true, Wiped = true }

local END_MESSAGES = {
	FarmLost = "The Great Pumpkin has fallen! The harvest is lost...",
	Wiped = "Everyone was knocked out! The harvest is lost...",
	Extracted = "Everyone escaped. Well farmed!",
	Abandoned = "The farm was abandoned.",
}

local function getMatchesFolder(): Folder
	local existing = Workspace:FindFirstChild("Matches")
	if existing then
		return existing :: Folder
	end
	local folder = Instance.new("Folder")
	folder.Name = "Matches"
	folder.Parent = Workspace
	return folder
end

function Match.new(id: number, arenaIndex: number, origin: Vector3, sessions: { any })
	local self = setmetatable({}, Match)
	self.Id = id
	self.ArenaIndex = arenaIndex
	self.Seed = Random.new():NextInteger(1, 2 ^ 30)
	self.Rng = Random.new(self.Seed)
	self.Janitor = Janitor.new()
	self.Sessions = {} :: { [Player]: any }
	self.Wave = 0
	self.ContinueLevel = 0
	self.IsBossWave = false
	self.PhaseEndsAt = 0
	self.EndReason = nil :: string?
	self.Destroyed = false
	self._firstIntermission = true

	local folder = Instance.new("Folder")
	folder.Name = `Match_{id}`
	folder:SetAttribute(Attributes.MatchId, id)
	self.Folder = folder
	self.Janitor:Add(folder)
	for _, childName in { "Enemies", "Crops", "Defenses" } do
		local child = Instance.new("Folder")
		child.Name = childName
		child.Parent = folder
	end

	self.Arena = MapBuilder.BuildArena(folder, origin)
	folder.Parent = getMatchesFolder()

	self.Core = FarmCore.new(self, self.Arena.CoreCFrame)
	self.Janitor:Add(self.Core)
	self.Janitor:Connect(self.Core.Destroyed, function()
		self:RequestEnd("FarmLost")
	end)

	for _, session in sessions do
		self.Sessions[session.Player] = session
		session.Match = self
		session.Player:SetAttribute(Attributes.MatchId, id)
	end

	self.Machine = self:_buildStateMachine()
	self.Janitor:Add(self.Machine)
	self:SetAttribute(Attributes.Wave, 0)
	self:SetAttribute(Attributes.ContinueLevel, 0)
	self:SetAttribute(Attributes.DifficultyMultiplier, 1)
	return self
end

-- Queries -----------------------------------------------------------------------------

function Match:GetPlayers(): { Player }
	local list = {}
	for player in self.Sessions do
		table.insert(list, player)
	end
	return list
end

function Match:GetSessions(): { any }
	local list = {}
	for _, session in self.Sessions do
		table.insert(list, session)
	end
	return list
end

function Match:GetLivingSessions(): { any }
	local list = {}
	for _, session in self.Sessions do
		if session.LifeState == LifeState.InMatch and session:IsAlive() then
			table.insert(list, session)
		end
	end
	return list
end

function Match:GetPlayerCount(): number
	local count = 0
	for _ in self.Sessions do
		count += 1
	end
	return count
end

function Match:GetContext()
	return { Wave = math.max(1, self.Wave), ContinueLevel = self.ContinueLevel, PlayerCount = math.max(1, self:GetPlayerCount()) }
end

function Match:GetState(): string
	return self.Machine:GetState() or MatchState.Waiting
end

function Match:IsCombatState(): boolean
	local state = self:GetState()
	return state == MatchState.WaveActive or state == MatchState.BossWave
end

-- Replication helpers ---------------------------------------------------------------------

function Match:SetAttribute(name: string, value: any)
	if not self.Destroyed then
		self.Folder:SetAttribute(name, value)
	end
end

function Match:SetPhaseDuration(seconds: number?)
	self.PhaseEndsAt = if seconds then Clock.Now() + seconds else 0
	self:SetAttribute(Attributes.PhaseEndsAt, self.PhaseEndsAt)
end

function Match:_phaseExpired(): boolean
	return self.PhaseEndsAt > 0 and Clock.Now() >= self.PhaseEndsAt
end

function Match:SetObjective(text: string)
	self:SetAttribute(Attributes.Objective, text)
end

function Match:FireAll(remoteName: string, ...: any)
	Services.RemoteService:FireClients(remoteName, self:GetPlayers(), ...)
end

function Match:Notify(text: string, kind: string?, duration: number?)
	self:FireAll("Notify", { Text = text, Kind = kind or "Info", Duration = duration or 4 })
end

-- Player flow ---------------------------------------------------------------------------

function Match:_spawnPoint(index: number): CFrame
	local spawns = self.Arena.PlayerSpawns
	return spawns[((index - 1) % #spawns) + 1]
end

function Match:_spawnSession(session: any, index: number)
	task.spawn(function()
		if self.Destroyed or self.Sessions[session.Player] ~= session then
			return
		end
		if not Services.PlayerService:SpawnInMatch(session, self:_spawnPoint(index)) then
			warn(`[Match {self.Id}] failed to spawn {session.Player.Name}`)
		end
	end)
end

function Match:_reviveDowned()
	local index = 0
	for _, session in self.Sessions do
		index += 1
		if session.LifeState == LifeState.Downed then
			self:_spawnSession(session, index)
		end
	end
end

function Match:OnPlayerDowned(session: any)
	self:Notify(`{session.Player.DisplayName} was knocked out!`, "Warning")
	if self:IsCombatState() then
		if #self:GetLivingSessions() == 0 then
			self:RequestEnd("Wiped")
		end
	elseif self:GetState() ~= MatchState.MatchEnding and self:GetState() ~= MatchState.Cleanup then
		-- Outside combat (e.g. a fall during intermission) players come straight back.
		task.delay(MatchConfig.Lobby.RespawnDelay, function()
			if not self.Destroyed and self.Sessions[session.Player] == session and session.LifeState == LifeState.Downed then
				self:_spawnSession(session, 1)
			end
		end)
	end
end

-- Removes a session from this match without touching its character or lobby state
-- (MatchService handles that). Ends the match when nobody is left.
function Match:DetachSession(session: any)
	if self.Sessions[session.Player] ~= session then
		return
	end
	self.Sessions[session.Player] = nil
	if next(self.Sessions) == nil then
		-- During Extraction an empty match means everyone escaped; the Extraction
		-- state resolves that itself as a normal "Extracted" ending.
		if self:GetState() ~= MatchState.Extraction then
			self:RequestEnd("Abandoned")
		end
	elseif self:IsCombatState() and #self:GetLivingSessions() == 0 then
		self:RequestEnd("Wiped")
	end
end

function Match:RequestEnd(reason: string)
	local state = self:GetState()
	if state == MatchState.MatchEnding or state == MatchState.Cleanup or self.Destroyed then
		return
	end
	self.EndReason = reason
	self.Machine:Transition(MatchState.MatchEnding, reason)
end

-- State machine ---------------------------------------------------------------------------

function Match:_enterState(state: string)
	self:SetAttribute(Attributes.State, state)
	Services.SeedShopService:SetOpen(self, table.find(MatchConfig.SeedShopOpenStates, state) ~= nil)
end

function Match:_buildStateMachine()
	local phases = MatchConfig.Phases
	local states = {}

	states[MatchState.Waiting] = {
		Enter = function()
			self:_enterState(MatchState.Waiting)
			self:SetObjective("Get ready...")
			self:SetPhaseDuration(phases.WaitingTimeout)
			local index = 0
			for _, session in self.Sessions do
				index += 1
				self:_spawnSession(session, index)
			end
		end,
		Update = function(machine)
			local everyoneReady = true
			for _, session in self.Sessions do
				if not session:IsAlive() then
					everyoneReady = false
					break
				end
			end
			if everyoneReady or self:_phaseExpired() then
				machine:Transition(MatchState.Starting)
			end
		end,
	}

	states[MatchState.Starting] = {
		Enter = function()
			self:_enterState(MatchState.Starting)
			self:SetObjective("Plant seeds and build defenses before the zombies arrive!")
			self:SetPhaseDuration(phases.Starting)
			for player, _ in self.Sessions do
				local startingCoins = EconomyConfig.MatchCoins.Starting + Services.UpgradeService:GetStartingCoinBonus(player)
				Services.MatchCoinService:Reset(player, startingCoins)
				Services.SeedService:GrantSoftLockIfNeeded(player)
			end
			Services.SeedShopService:Restock(self)
			self:Notify("Protect the Pumpkin Farm! Plant seeds, then survive the night.", "Info", 6)
		end,
		Update = function(machine)
			if self:_phaseExpired() then
				machine:Transition(MatchState.Intermission)
			end
		end,
	}

	states[MatchState.Intermission] = {
		Enter = function()
			self:_enterState(MatchState.Intermission)
			local duration = if self._firstIntermission then phases.FirstIntermission else phases.Intermission
			if not self._firstIntermission then
				Services.SeedShopService:Restock(self)
			end
			self._firstIntermission = false
			self:SetObjective("Intermission: buy seeds, plant, harvest and fortify!")
			self:SetPhaseDuration(duration)
		end,
		Update = function(machine)
			if self:_phaseExpired() then
				machine:Transition(MatchState.PreparingWave)
			end
		end,
	}

	states[MatchState.PreparingWave] = {
		Enter = function()
			self:_enterState(MatchState.PreparingWave)
			self.Wave += 1
			self.IsBossWave = Services.DifficultyService:IsBossWave(self.Wave)
			self:SetAttribute(Attributes.Wave, self.Wave)
			self:SetAttribute(Attributes.IsBossWave, self.IsBossWave)
			Services.WaveService:PrepareWave(self)
			self:SetPhaseDuration(phases.PreparingWave)
			if self.IsBossWave then
				self:SetObjective("THE CURSED HARVESTER APPROACHES!")
				self:FireAll("MatchEvent", "BossIncoming", { Wave = self.Wave })
			else
				self:SetObjective(`Wave {self.Wave} incoming!`)
				self:FireAll("MatchEvent", "WaveIncoming", { Wave = self.Wave })
			end
		end,
		Update = function(machine)
			if self:_phaseExpired() then
				machine:Transition(if self.IsBossWave then MatchState.BossWave else MatchState.WaveActive)
			end
		end,
	}

	local function combatState(stateName: string)
		return {
			Enter = function()
				self:_enterState(stateName)
				self:SetPhaseDuration(nil)
				self:SetObjective(if stateName == MatchState.BossWave
					then "Defeat the Cursed Harvester and protect the crops!"
					else "Defend the farm! Harvest ripe crops when you can.")
				Services.WaveService:StartWave(self)
				self:FireAll("MatchEvent", "WaveStarted", { Wave = self.Wave, IsBoss = stateName == MatchState.BossWave })
			end,
			Update = function(machine, dt)
				Services.WaveService:Update(self, dt)
				if Services.WaveService:IsWaveCleared(self) then
					machine:Transition(MatchState.WaveComplete)
				end
			end,
		}
	end
	states[MatchState.WaveActive] = combatState(MatchState.WaveActive)
	states[MatchState.BossWave] = combatState(MatchState.BossWave)

	states[MatchState.WaveComplete] = {
		Enter = function()
			self:_enterState(MatchState.WaveComplete)
			self:SetPhaseDuration(phases.WaveComplete)
			self:SetObjective(`Wave {self.Wave} survived!`)
			Services.RewardService:OnWaveCompleted(self)
			self:FireAll("MatchEvent", "WaveCompleted", { Wave = self.Wave })
			self:_reviveDowned()
		end,
		Update = function(machine)
			if self:_phaseExpired() then
				if self.Wave % MatchConfig.ExtractionEveryWaves == 0 then
					machine:Transition(MatchState.Extraction)
				else
					machine:Transition(MatchState.Intermission)
				end
			end
		end,
	}

	states[MatchState.Extraction] = {
		Enter = function()
			self:_enterState(MatchState.Extraction)
			self:SetPhaseDuration(phases.ExtractionDecision)
			self:SetObjective("The Escape Door is open! ESCAPE with the harvest, or CONTINUE for more.")
			Services.EscapeService:OpenDoor(self)
		end,
		Update = function(machine)
			local resolution = Services.EscapeService:Update(self, self:_phaseExpired())
			if resolution == "Continue" then
				machine:Transition(MatchState.ContinuePreparation)
			elseif resolution == "End" then
				self.EndReason = "Extracted"
				machine:Transition(MatchState.MatchEnding, "Extracted")
			end
		end,
		Exit = function()
			Services.EscapeService:CloseDoor(self)
		end,
	}

	states[MatchState.ContinuePreparation] = {
		Enter = function()
			self:_enterState(MatchState.ContinuePreparation)
			local difficulty = Services.DifficultyService
			self.ContinueLevel = math.min(self.ContinueLevel + 1, DifficultyConfig.Continue.MaxLevel)
			local danger = difficulty:GetDangerMultiplier(self.ContinueLevel)
			self:SetAttribute(Attributes.ContinueLevel, self.ContinueLevel)
			self:SetAttribute(Attributes.DifficultyMultiplier, danger)
			self:SetPhaseDuration(phases.ContinuePreparation)
			self:SetObjective(`DANGER LEVEL {Format.Roman(self.ContinueLevel)}: prepare! Zombies are {Format.Multiplier(danger)} tougher.`)

			local recovery = MatchConfig.ContinueRecovery
			if recovery.HealPlayers then
				for _, session in self.Sessions do
					local humanoid = session.Humanoid
					if humanoid and session:IsAlive() then
						humanoid.Health = humanoid.MaxHealth
					end
				end
			end
			Services.DefenseService:RepairAll(self, recovery.RepairDefensesFraction)
			self.Core:Heal(recovery.CoreHealFraction)
			Services.CropService:HealAll(self)
			Services.SeedShopService:Restock(self)
			self:FireAll("MatchEvent", "ContinueStarted", { ContinueLevel = self.ContinueLevel, Danger = danger })
		end,
		Update = function(machine)
			if self:_phaseExpired() then
				machine:Transition(MatchState.PreparingWave)
			end
		end,
	}

	states[MatchState.MatchEnding] = {
		Enter = function(_machine, _from, reason)
			local endReason = reason or self.EndReason or "Abandoned"
			self.EndReason = endReason
			self:_enterState(MatchState.MatchEnding)
			self:SetPhaseDuration(phases.MatchEnding)
			self:SetObjective(END_MESSAGES[endReason] or "The match is over.")
			Services.WaveService:StopWave(self)
			if LOSS_REASONS[endReason] then
				Services.HarvestChestService:Forfeit(self)
			end
			for _, session in self.Sessions do
				Services.RewardService:CommitMatchStats(session, self, false)
			end
			self:FireAll("MatchEvent", "MatchEnded", {
				Reason = endReason,
				Wave = self.Wave,
				ContinueLevel = self.ContinueLevel,
				Lost = LOSS_REASONS[endReason] == true,
			})
		end,
		Update = function(machine)
			if self:_phaseExpired() or next(self.Sessions) == nil then
				machine:Transition(MatchState.Cleanup)
			end
		end,
	}

	states[MatchState.Cleanup] = {
		Enter = function()
			self:_enterState(MatchState.Cleanup)
			self:SetPhaseDuration(nil)
			-- Defer so the state machine finishes its transition before teardown.
			task.defer(function()
				Services.MatchService:DestroyMatch(self)
			end)
		end,
	}

	return StateMachine.new({
		Name = `Match_{self.Id}`,
		Initial = MatchState.Waiting,
		States = states,
		Transitions = {
			[MatchState.Waiting] = { MatchState.Starting, MatchState.MatchEnding },
			[MatchState.Starting] = { MatchState.Intermission, MatchState.MatchEnding },
			[MatchState.Intermission] = { MatchState.PreparingWave, MatchState.MatchEnding },
			[MatchState.PreparingWave] = { MatchState.WaveActive, MatchState.BossWave, MatchState.MatchEnding },
			[MatchState.WaveActive] = { MatchState.WaveComplete, MatchState.MatchEnding },
			[MatchState.BossWave] = { MatchState.WaveComplete, MatchState.MatchEnding },
			[MatchState.WaveComplete] = { MatchState.Intermission, MatchState.Extraction, MatchState.MatchEnding },
			[MatchState.Extraction] = { MatchState.ContinuePreparation, MatchState.MatchEnding },
			[MatchState.ContinuePreparation] = { MatchState.PreparingWave, MatchState.MatchEnding },
			[MatchState.MatchEnding] = { MatchState.Cleanup },
			[MatchState.Cleanup] = {},
		},
	})
end

-- Lifecycle --------------------------------------------------------------------------------

function Match:Start()
	self.Machine:Start()
end

function Match:Update(dt: number)
	if self.Destroyed then
		return
	end
	self.Machine:Update(dt)
end

function Match:Destroy()
	if self.Destroyed then
		return
	end
	self.Destroyed = true
	self.Janitor:Destroy()
end

return Match
