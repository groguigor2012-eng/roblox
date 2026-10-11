--!strict
-- Client entry point. Waits only for what it needs (the server-created
-- remotes), verifies the remote contract, then starts each controller once:
--   1. CharacterLifecycle           character spawn/death/despawn fan-out
--   2. CollectibleVisualController  collectible visuals + pickup requests
--   3. MovementController           move set and local effects
--   4. HeartUIController            three-heart health display
--   5. FeedbackController           damage flash + camera shake
-- Controllers register with CharacterLifecycle, so they re-bind to every new
-- character automatically. A controller that fails to start is logged and
-- skipped; the others keep working (e.g. a UI error never disables movement).
-- FeedbackController is required before MovementController (which calls its
-- AddTrauma), but its Start only builds UI and registers handlers, so order
-- between the two Starts does not matter.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Config"):WaitForChild("GameConfig"))
local Logger = require(Shared:WaitForChild("Utilities"):WaitForChild("Logger"))
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent
local CharacterLifecycle = require(Client.Utilities.CharacterLifecycle)
local Controllers = Client.Controllers
local CollectibleVisualController = require(Controllers.CollectibleVisualController)
local MovementController = require(Controllers.MovementController)
local HeartUIController = require(Controllers.HeartUIController)
local FeedbackController = require(Controllers.FeedbackController)

local logger = Logger.new("ClientBootstrap")

if script:GetAttribute("Started") then
	error("Platformer client bootstrap ran twice; remove the duplicate Bootstrap script")
end
script:SetAttribute("Started", true)

local function waitForRemotes(): Types.Remotes?
	local timeout = GameConfig.RemoteWaitTimeout
	local folder = Shared:WaitForChild(GameConfig.Folders.Remotes, timeout)
	if not folder then
		logger:Error("RemotesMissing", { Folder = GameConfig.Folders.Remotes, Timeout = timeout })
		return nil
	end
	local remotes: { [string]: RemoteEvent } = {}
	for name, className in GameConfig.Remotes do
		local remote = folder:WaitForChild(name, timeout)
		if not remote or not remote:IsA(className) then
			logger:Error("RemoteInvalid", { Name = name, Expected = className, Found = remote and remote.ClassName })
			return nil
		end
		remotes[name] = remote :: RemoteEvent
	end
	return (remotes :: any) :: Types.Remotes
end

local function traceback(err: any): string
	return debug.traceback(tostring(err), 2)
end

local function start(name: string, step: () -> ())
	local ok, err = xpcall(function(): string?
		step()
		return nil
	end, traceback)
	if not ok then
		logger:Error("ControllerFailed", { Controller = name, Error = err })
	end
end

local remotes = waitForRemotes()

start("CharacterLifecycle", CharacterLifecycle.Start)
if remotes then
	start("CollectibleVisualController", function()
		CollectibleVisualController.Init(remotes)
		CollectibleVisualController.Start()
	end)
	start("MovementController", function()
		MovementController.Init(remotes)
		MovementController.Start()
	end)
else
	logger:Error("NetworkedControllersSkipped", { Reason = "remote contract unavailable" })
end
start("HeartUIController", HeartUIController.Start)
start("FeedbackController", FeedbackController.Start)
