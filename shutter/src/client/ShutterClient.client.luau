--!strict
-- THE SHUTTER client bootstrap. The only LocalScript; everything else is a module.
-- The server's ShutterCamcorder attribute is the single source of truth for which reality
-- this client draws.

local folder = script.Parent

local RealityRenderer = require(folder:WaitForChild("RealityRenderer"))
local CamcorderHud = require(folder:WaitForChild("CamcorderHud"))
local CamcorderController = require(folder:WaitForChild("CamcorderController"))
local WatcherFX = require(folder:WaitForChild("WatcherFX"))
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shutter"):WaitForChild("Config"))

RealityRenderer.start()
CamcorderHud.start()

CamcorderController.onFilmingChanged(function(filming: boolean)
	RealityRenderer.setFilming(filming)
	CamcorderHud.setFilming(filming)
	CamcorderHud.playSound(if filming then Config.FX.CAMCORDER_ON_SOUND else Config.FX.CAMCORDER_OFF_SOUND, 0.6)
end)

CamcorderController.start()
WatcherFX.start()
