--!strict
-- Server entry point. Starts every service exactly once, in dependency order:
--   1. RemoteRegistry           create/verify the remote contract
--   2. CharacterService         collision groups, health, character records
--   3. PlayerDataService        DataStore, session locks, leaderstats
--   4. ProgressionService       trusted reward path (needs 3)
--   5. DestructibleService      breakable registry
--   6. CollectibleService       collectible registry + pickup remote (needs 2-4)
--   7. MovementValidationService movement + impact remotes (needs 2, 5)
--   8. DemoCourse               optional test level (GameConfig.DemoCourse.Mode)
--
-- Failure policy: steps 1-7 are security- or data-critical. If any fails, the
-- server stops starting further services and kicks every current and future
-- player with an explanation rather than running half-wired.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local DataConfig = require(Shared.Config.DataConfig)
local Logger = require(Shared.Utilities.Logger)
local Types = require(Shared.Types)

local Server = script.Parent
local Services = Server.Services
local Utilities = Server.Utilities

local RemoteRegistry = require(Utilities.RemoteRegistry)
local DemoCourse = require(Utilities.DemoCourse)
local CharacterService = require(Services.CharacterService)
local PlayerDataService = require(Services.PlayerDataService)
local ProgressionService = require(Services.ProgressionService)
local DestructibleService = require(Services.DestructibleService)
local CollectibleService = require(Services.CollectibleService)
local MovementValidationService = require(Services.MovementValidationService)

local logger = Logger.new("ServerBootstrap")

if script:GetAttribute("Started") then
	error("Platformer server bootstrap ran twice; remove the duplicate Bootstrap script")
end
script:SetAttribute("Started", true)

local function traceback(err: any): string
	return debug.traceback(tostring(err), 2)
end

-- Runs fn and returns (true, nil) or (false, error with traceback).
local function try(fn: () -> ()): (boolean, string?)
	return xpcall(function(): string?
		fn()
		return nil
	end, traceback)
end

local function lockDown(stage: string, err: any)
	logger:Error("StartupFailed", { Stage = stage, Error = tostring(err) })
	local function reject(player: Player)
		player:Kick(DataConfig.KickMessages.ServerUnavailable)
	end
	Players.PlayerAdded:Connect(reject)
	for _, player in Players:GetPlayers() do
		reject(player)
	end
end

local function run(stage: string, step: () -> ()): boolean
	local ok, err = try(step)
	if not ok then
		lockDown(stage, err)
	end
	return ok
end

local remotes: Types.Remotes? = nil
local steps: { { Name: string, Run: () -> () } } = {
	{
		Name = "RemoteRegistry",
		Run = function()
			remotes = RemoteRegistry.Create()
		end,
	},
	{ Name = "CharacterService", Run = CharacterService.Start },
	{ Name = "PlayerDataService", Run = PlayerDataService.Start },
	{ Name = "ProgressionService", Run = ProgressionService.Start },
	{ Name = "DestructibleService", Run = DestructibleService.Start },
	{
		Name = "CollectibleService",
		Run = function()
			CollectibleService.Init(remotes :: Types.Remotes)
			CollectibleService.Start()
		end,
	},
	{
		Name = "MovementValidationService",
		Run = function()
			MovementValidationService.Init(remotes :: Types.Remotes)
			MovementValidationService.Start()
		end,
	},
}

local allStarted = true
for _, step in steps do
	if not run(step.Name, step.Run) then
		allStarted = false
		break
	end
end

if allStarted then
	if DemoCourse.ShouldBuild() then
		local ok, err = try(DemoCourse.Build)
		if not ok then
			-- Optional content: log it, the framework itself is running.
			logger:Error("DemoCourseFailed", { Error = tostring(err) })
		end
	end
	logger:Info("Started", { MemoryStore = PlayerDataService.IsUsingMemoryStore() })
end
