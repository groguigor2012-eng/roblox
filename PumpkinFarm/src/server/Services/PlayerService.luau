--!strict
--[[
	PlayerService
	Path: ServerScriptService.Server.Services.PlayerService

	Owns the player lifecycle: session creation, profile loading, spawning (characters
	never auto-load; the server decides where and when a player exists), death handling
	and orderly teardown on leave.

	Join:   session -> lobby spawn (immediately) + profile load in parallel (safe state
	        on failure: no queueing, no persistent rewards) -> equipped class applied
	Death:  lobby  -> respawn in the lobby after Lobby.RespawnDelay
	        match  -> Downed until the wave ends (Match revives them), team-wipe check
	Leave:  leave queue -> leave match (stats committed) -> release profile -> cleanup

	Also answers RequestSnapshot (profile/shop/chest/extraction for a reloading UI) and
	RequestUpdateSettings (persisted boolean settings).

	Dependencies: PlayerSession, CollisionGroups, CollisionGroup, LifeState, MatchConfig,
	              Signal, Result;
	              Registry: DataService, ClassService, LobbyService, MatchService,
	              StatusEffectService, WeaponService, RemoteService, SeedShopService,
	              HarvestChestService, EscapeService

	API:
		PlayerService:GetSession(player) -> PlayerSession?
		PlayerService:GetSessions() -> { PlayerSession }
		PlayerService:SpawnAsync(session, cframe) -> boolean
		PlayerService:SpawnInLobby(session)
		PlayerService:SpawnInMatch(session, cframe) -> boolean
		PlayerService:Notify(player, text, kind?, duration?)
		PlayerService:GetSnapshot(player) -> Snapshot          (RequestSnapshot)
		PlayerService.SessionAdded : Signal(session)
		PlayerService.SessionRemoving : Signal(session)
		PlayerService.CharacterDied : Signal(session)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local CollisionGroup = require(Shared.Constants.CollisionGroup)
local LifeState = require(Shared.Constants.LifeState)
local MatchConfig = require(Shared.Config.MatchConfig)
local Result = require(Shared.Utilities.Result)
local Signal = require(Shared.Classes.Signal)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local PlayerSession = require(Server.Classes.PlayerSession)
local CollisionGroups = require(Server.Systems.CollisionGroups)

local PlayerService = {}
PlayerService.SessionAdded = Signal.new()
PlayerService.SessionRemoving = Signal.new()
PlayerService.CharacterDied = Signal.new()

local sessions: { [Player]: any } = {}

function PlayerService:Init() end

function PlayerService:GetSession(player: Player): any
	return sessions[player]
end

function PlayerService:GetSessions(): { any }
	local list = {}
	for _, session in sessions do
		table.insert(list, session)
	end
	return list
end

function PlayerService:Notify(player: Player, text: string, kind: string?, duration: number?)
	Services.RemoteService:FireClient("Notify", player, { Text = text, Kind = kind or "Info", Duration = duration or 4 })
end

local function onCharacterDied(session: any)
	local state = session.LifeState
	Services.StatusEffectService:ClearTarget(session)
	Services.WeaponService:UnequipWeapon(session)
	PlayerService.CharacterDied:Fire(session)

	if state == LifeState.InMatch then
		session:SetLifeState(LifeState.Downed)
		local match = session.Match
		if match then
			match:OnPlayerDowned(session)
		end
	elseif state == LifeState.Lobby or state == LifeState.Queued then
		local token = session.SpawnToken
		task.delay(MatchConfig.Lobby.RespawnDelay, function()
			if session.Destroyed or session.SpawnToken ~= token then
				return
			end
			if session.LifeState == LifeState.Lobby or session.LifeState == LifeState.Queued then
				PlayerService:SpawnInLobby(session)
			end
		end)
	end
end

-- Loads a character and places it. A SpawnToken guards against overlapping spawn
-- requests (e.g. a lobby respawn racing a match start): only the latest one wins.
function PlayerService:SpawnAsync(session: any, cframe: CFrame): boolean
	local player: Player = session.Player
	session.SpawnToken += 1
	local token = session.SpawnToken

	local ok, err = pcall(function()
		player:LoadCharacter()
	end)
	if not ok then
		warn(`[PlayerService] LoadCharacter failed for {player.Name}: {err}`)
		return false
	end
	if session.Destroyed or session.SpawnToken ~= token or player.Parent ~= Players then
		return false
	end

	local character = player.Character
	if character == nil then
		return false
	end
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if root == nil or session.SpawnToken ~= token then
		return false
	end
	if not session:BindCharacter(character) then
		return false
	end

	-- Players pass through their own defenses (see CollisionGroups); parts added later
	-- (accessories, the weapon) join the group too.
	CollisionGroups.SetModel(character, CollisionGroup.Players)
	session.CharacterJanitor:Connect(character.DescendantAdded, function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = CollisionGroup.Players
		end
	end)
	character:PivotTo(cframe)
	local humanoid = session.Humanoid :: Humanoid
	session.CharacterJanitor:Connect(humanoid.Died, function()
		if session.Character == character then
			onCharacterDied(session)
		end
	end)
	return true
end

function PlayerService:SpawnInLobby(session: any)
	Services.WeaponService:UnequipWeapon(session)
	if session.LifeState ~= LifeState.Queued then
		session:SetLifeState(LifeState.Lobby)
	end
	if self:SpawnAsync(session, Services.LobbyService:GetSpawnCFrame()) then
		Services.ClassService:ApplyToCharacter(session)
	end
end

function PlayerService:SpawnInMatch(session: any, cframe: CFrame): boolean
	session:SetLifeState(LifeState.InMatch)
	if not self:SpawnAsync(session, cframe) then
		return false
	end
	Services.ClassService:ApplyToCharacter(session)
	Services.WeaponService:EquipWeapon(session)
	Services.StatusEffectService:Apply(session, "SpawnProtection")
	return true
end

local function onPlayerAdded(player: Player)
	if sessions[player] then
		return
	end
	local session = PlayerSession.new(player)
	sessions[player] = session

	-- The player walks around the lobby immediately; the profile loads in parallel
	-- (it can take a while if another server still holds the session lock). Queueing
	-- and every persistent-currency action stay disabled until the load succeeds.
	Services.ClassService:InitializePlayer(session)
	session:SetLifeState(LifeState.Lobby)
	task.spawn(function()
		PlayerService:SpawnInLobby(session)
	end)

	local ok, problem = Services.DataService:LoadProfileAsync(player)
	if player.Parent ~= Players or session.Destroyed then
		return
	end
	if not ok then
		warn(`[PlayerService] profile load failed for {player.UserId}: {problem}`)
		PlayerService:Notify(
			player,
			"Your save data could not be loaded. You can explore the lobby, but matches are disabled. Please rejoin.",
			"Error",
			12
		)
	end

	-- Apply the equipped costume from the freshly loaded profile.
	Services.ClassService:InitializePlayer(session)
	Services.ClassService:ApplyToCharacter(session)
	PlayerService.SessionAdded:Fire(session)
end

local function onPlayerRemoving(player: Player)
	local session = sessions[player]
	if session == nil then
		Services.DataService:ReleaseProfile(player)
		return
	end
	PlayerService.SessionRemoving:Fire(session)
	Services.LobbyService:LeaveQueue(player)
	Services.MatchService:OnPlayerRemoving(session)
	Services.StatusEffectService:ClearTarget(session)
	Services.DataService:ReleaseProfile(player)
	session:Destroy()
	sessions[player] = nil
end

-- Everything a (re)loading client needs to rebuild its UI in one round trip.
function PlayerService:GetSnapshot(player: Player): any
	local session = sessions[player]
	local match = session and session.Match
	return {
		Profile = Services.DataService:GetProfileView(player),
		Shop = match and Services.SeedShopService:GetSnapshot(match, player),
		Chest = match and Services.HarvestChestService:GetSnapshot(match),
		Extraction = match and Services.EscapeService:GetSnapshot(match, player),
	}
end

function PlayerService:Start()
	Services.RemoteService:OnInvoke("RequestSnapshot", function(player: Player)
		return Result.Ok(self:GetSnapshot(player))
	end)
	Services.RemoteService:OnEvent("RequestUpdateSettings", function(player: Player, key: string, value: boolean)
		Services.DataService:SetSetting(player, key, value)
	end)

	Players.CharacterAutoLoads = false
	Players.PlayerAdded:Connect(function(player)
		onPlayerAdded(player)
	end)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return PlayerService
