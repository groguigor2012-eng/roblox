--!strict
-- WatcherFX (client): what the player FEELS of the Watcher. Display only.
--   * Camcorder interference rises as any Watcher gets closer (only visible while filming,
--     so the naked-eye world stays pristine).
--   * "SUBJECT HELD" shows while the server reports the Watcher frozen AND it is on screen.
--   * The server's "Caught" message plays the jumpscare.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shutter")
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))
local CamcorderHud = require(script.Parent:WaitForChild("CamcorderHud"))
local RealityRenderer = require(script.Parent:WaitForChild("RealityRenderer"))

local FX = Config.FX
local ATTR = Config.Attributes

local WatcherFX = {}

local staticSound: Sound? = nil

local function nearestWatcher(from: Vector3): (Model?, number)
	local best: Model? = nil
	local bestDistance = math.huge
	for _, instance in CollectionService:GetTagged(Config.Tags.Entity) do
		if instance:IsA("Model") and instance:IsDescendantOf(workspace) then
			local distance = (instance:GetPivot().Position - from).Magnitude
			if distance < bestDistance then
				best, bestDistance = instance, distance
			end
		end
	end
	return best, bestDistance
end

local function update()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local filming = RealityRenderer.isFilming()
	local watcher, distance = nearestWatcher(camera.CFrame.Position)
	local level = 0
	if watcher then
		level = math.clamp(1 - distance / FX.STATIC_START_DISTANCE, 0, 1)
	end
	CamcorderHud.setInterference(level)

	local held = false
	if filming and watcher and watcher:GetAttribute(ATTR.WatcherFrozen) == true then
		local _, onScreen = camera:WorldToViewportPoint(watcher:GetPivot().Position)
		held = onScreen
	end
	CamcorderHud.setHeld(held)

	local sound = staticSound
	if sound then
		sound.Volume = if filming then level * 0.8 else 0
	end
end

function WatcherFX.start()
	if FX.STATIC_LOOP_SOUND ~= "" then
		local sound = Instance.new("Sound")
		sound.Name = "ShutterStatic"
		sound.SoundId = FX.STATIC_LOOP_SOUND
		sound.Looped = true
		sound.Volume = 0
		sound.Parent = script
		sound:Play()
		staticSound = sound
	end

	Net.WatcherFeedback.OnClientEvent:Connect(function(kind: unknown, _data: unknown)
		if kind == "Caught" then
			CamcorderHud.playCaught()
			CamcorderHud.playSound(FX.JUMPSCARE_SOUND, 1)
		end
	end)

	RunService.RenderStepped:Connect(update)
end

return WatcherFX
