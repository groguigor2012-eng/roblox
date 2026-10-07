--!strict
--[[
	DebugService
	Path: ServerScriptService.Server.Services.DebugService

	Server-gated test commands for Studio play-testing (see docs/TESTING.md). Gated by
	DebugConfig (Enabled + Studio or allow-listed UserId); in a live game with
	Enabled = false nothing is connected at all. Commands act only through the same
	services gameplay uses, so they exercise real code paths.

		/pf help                       list commands
		/pf coins <n>                  grant Match Coins
		/pf candies <n>                grant Candies (persisted)
		/pf seeds <SeedId> <n>         grant seeds (persisted)
		/pf skip                       end the current phase / clear the current wave
		/pf wave <n>                   the next wave will be wave n
		/pf spawn <EnemyId> [count]    spawn enemies near the speaker
		/pf boss                       spawn the Cursed Harvester
		/pf ripen                      ripen every crop in the match
		/pf extract                    open the Escape Door now
		/pf killall                    kill every enemy in the match
		/pf stun                       stun yourself (tests StunService)
		/pf stats                      print server diagnostics
		/pf verbose                    toggle Candy transaction logging

	Dependencies: DebugConfig, EnemyConfig, MatchState, CurrencyId;
	              Registry: PlayerService, MatchService, CurrencyService, SeedService,
	              WaveService, EnemyService, CropService, StunService, CandyService
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage.Shared
local Clock = require(Shared.Utilities.Clock)
local CurrencyId = require(Shared.Constants.CurrencyId)
local EnemyConfig = require(Shared.Config.EnemyConfig)
local MatchConfig = require(Shared.Config.MatchConfig)
local MatchState = require(Shared.Constants.MatchState)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local DebugConfig = require(Server.DebugConfig)
local PathQueue = require(Server.AI.PathQueue)

local DebugService = {}

local lastCommand: { [Player]: { Text: string, At: number } } = {}

local function allowed(player: Player): boolean
	if not DebugConfig.Enabled then
		return false
	end
	if DebugConfig.AllowInStudio and RunService:IsStudio() then
		return true
	end
	return table.find(DebugConfig.AllowedUserIds, player.UserId) ~= nil
end

local function reply(player: Player, text: string)
	Services.PlayerService:Notify(player, "[debug] " .. text, "Info", 6)
end

local function number(value: string?, default: number): number
	local parsed = tonumber(value)
	if parsed == nil or parsed ~= parsed then
		return default
	end
	return math.floor(parsed)
end

local commands: { [string]: (Player, any, { string }) -> () } = {}

commands.help = function(player)
	reply(player, "coins, candies, seeds, skip, wave, spawn, boss, ripen, extract, killall, stun, stats, verbose")
end

commands.coins = function(player, _session, args)
	Services.CurrencyService:Grant(player, CurrencyId.MatchCoins, math.max(1, number(args[1], 500)), "Debug")
end

commands.candies = function(player, _session, args)
	Services.CurrencyService:Grant(player, CurrencyId.Candies, math.max(1, number(args[1], 1000)), "Debug")
end

commands.seeds = function(player, _session, args)
	if not Services.SeedService:AddSeeds(player, args[1] or "NeonStarFruit", math.max(1, number(args[2], 5)), "Debug") then
		reply(player, "unknown seed id")
	end
end

commands.skip = function(player, session)
	local match = session.Match
	if match == nil then
		return reply(player, "not in a match")
	end
	if match:IsCombatState() then
		Services.WaveService:ForceComplete(match)
	else
		match:SetPhaseDuration(0.05)
	end
end

commands.wave = function(player, session, args)
	local match = session.Match
	if match == nil then
		return reply(player, "not in a match")
	end
	match.Wave = math.max(0, number(args[1], 1) - 1)
	reply(player, `next wave will be {match.Wave + 1}`)
end

commands.spawn = function(player, session, args)
	local match = session.Match
	local position = session:GetPosition()
	local enemyId = args[1] or "ZombieFarmer"
	if match == nil or position == nil then
		return reply(player, "not in a match")
	end
	if EnemyConfig.Get(enemyId) == nil then
		return reply(player, "unknown enemy id")
	end
	for index = 1, math.clamp(number(args[2], 1), 1, 20) do
		local angle = index * 0.9
		local offset = Vector3.new(math.cos(angle) * 25, 4, math.sin(angle) * 25)
		Services.EnemyService:SpawnEnemy(match, enemyId, CFrame.new(position + offset), { IsWaveEnemy = true })
	end
end

commands.boss = function(player, session)
	commands.spawn(player, session, { "CursedHarvester", "1" })
end

commands.ripen = function(player, session)
	if session.Match == nil then
		return reply(player, "not in a match")
	end
	Services.CropService:ForceRipenAll(session.Match)
end

commands.extract = function(player, session)
	local match = session.Match
	if match == nil then
		return reply(player, "not in a match")
	end
	-- Make the current wave an extraction wave, then end the phase/wave.
	local interval = MatchConfig.ExtractionEveryWaves
	if match:GetState() == MatchState.Intermission then
		match.Wave = interval - 1
		match:SetPhaseDuration(0.05)
		reply(player, "next wave ends at the Escape Door; clear it with /pf skip")
	elseif match:IsCombatState() then
		match.Wave = math.max(interval, math.ceil(match.Wave / interval) * interval)
		Services.WaveService:ForceComplete(match)
	else
		reply(player, "use during Intermission or a wave")
	end
end

commands.killall = function(player, session)
	if session.Match == nil then
		return reply(player, "not in a match")
	end
	Services.EnemyService:KillAll(session.Match)
end

commands.stun = function(player, session)
	reply(player, if Services.StunService:TryStun(session, 2, { Kind = "Environment" }) then "stunned" else "stun rejected (immune or already stunned)")
end

commands.stats = function(player)
	local matches = Services.MatchService:GetMatches()
	local enemies = 0
	for _, match in matches do
		enemies += Services.EnemyService:GetAliveCount(match)
	end
	local text = `matches={#matches} enemies={enemies} pathQueue={PathQueue.GetPending()} players={#Players:GetPlayers()} t={math.floor(Clock.Now())}`
	print("[DebugService] " .. text)
	reply(player, text)
end

commands.verbose = function(player)
	Services.CandyService.Verbose = not Services.CandyService.Verbose
	reply(player, `candy logging {if Services.CandyService.Verbose then "on" else "off"}`)
end

local function run(player: Player, text: string)
	if not allowed(player) then
		return
	end
	local prefix = DebugConfig.Prefix
	if text:sub(1, #prefix):lower() ~= prefix then
		return
	end
	-- TextChatCommand and Player.Chatted can both deliver the same message.
	local previous = lastCommand[player]
	local now = os.clock()
	if previous and previous.Text == text and now - previous.At < 0.5 then
		return
	end
	lastCommand[player] = { Text = text, At = now }

	local words = string.split(text:sub(#prefix + 1), " ")
	local args = {}
	for _, word in words do
		if word ~= "" then
			table.insert(args, word)
		end
	end
	local name = table.remove(args, 1)
	local command = name and commands[name:lower()]
	local session = Services.PlayerService:GetSession(player)
	if command == nil or session == nil then
		return reply(player, "unknown command, try /pf help")
	end
	local ok, err = pcall(command, player, session, args)
	if not ok then
		reply(player, `command failed: {err}`)
	end
end

function DebugService:Init() end

function DebugService:Start()
	if not DebugConfig.Enabled then
		return
	end
	local function hook(player: Player)
		if allowed(player) then
			player.Chatted:Connect(function(message)
				run(player, message)
			end)
		end
	end
	Players.PlayerAdded:Connect(hook)
	for _, player in Players:GetPlayers() do
		hook(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastCommand[player] = nil
	end)

	if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
		local command = Instance.new("TextChatCommand")
		command.Name = "PumpkinFarmDebug"
		command.PrimaryAlias = DebugConfig.Prefix
		command.Parent = TextChatService
		command.Triggered:Connect(function(source: TextSource, text: string)
			local player = Players:GetPlayerByUserId(source.UserId)
			if player then
				run(player, text)
			end
		end)
	end
end

return DebugService
