--!strict
-- THE SHUTTER server bootstrap. The only Script on the server; everything else is a module.
-- Start order matters: remotes -> demo map -> camcorder/battery core -> interactions -> the Watcher.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shutter")
require(Shared:WaitForChild("Net")) -- creates any missing remotes before clients look for them

local CamcorderService = require(script.Parent:WaitForChild("CamcorderService"))
local InteractionService = require(script.Parent:WaitForChild("InteractionService"))
local WatcherService = require(script.Parent:WaitForChild("WatcherService"))
local DemoLevel = require(script.Parent:WaitForChild("DemoLevel"))

DemoLevel.buildIfEmpty() -- before the Watcher, so its WatcherSpawn marker exists
CamcorderService.start()
InteractionService.start()
WatcherService.start()

print("[Shutter] Server systems online: Camcorder/Battery, Interaction, Watcher")
