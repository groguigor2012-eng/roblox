--!strict
-- Lighting, post-processing, terrain water and player defaults for the Poolrooms.
-- Goal: bright, soft, slightly overexposed daylight that seems to come from
-- nowhere in particular, with a faint dreamy haze over everything.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local StarterPlayer = game:GetService("StarterPlayer")

local Config = require(ReplicatedStorage:WaitForChild("Poolrooms"):WaitForChild("Config"))

-- Lighting ------------------------------------------------------------------------
-- Technology can only be changed in Studio (Lighting > Technology = Future), not by a
-- running script. default.project.json sets it for Rojo users; this just checks.
if Lighting.Technology ~= Enum.Technology.Future then
	warn("[Poolrooms] Set Lighting.Technology to Future in Studio for soft light and local shadows.")
end

Lighting.Brightness = 3
Lighting.ClockTime = 13 -- high sun: light falls straight down the atrium shafts
Lighting.GeographicLatitude = 20
Lighting.Ambient = Color3.fromRGB(150, 160, 156) -- lifts every indoor shadow
Lighting.OutdoorAmbient = Color3.fromRGB(205, 212, 208)
Lighting.ColorShift_Top = Color3.fromRGB(255, 248, 232) -- faintly warm sunlight
Lighting.ColorShift_Bottom = Color3.fromRGB(200, 236, 228) -- teal bounce from the water
Lighting.EnvironmentDiffuseScale = 1
Lighting.EnvironmentSpecularScale = 1 -- glossy tiles + water pick up the sky
Lighting.ExposureCompensation = 0.6 -- the slightly blown-out look
Lighting.GlobalShadows = true
Lighting.ShadowSoftness = 0.6

local function effect<T>(className: string, name: string): T
	local existing = Lighting:FindFirstChild(name)
	if existing then
		return existing :: any
	end
	local inst = Instance.new(className :: any)
	inst.Name = name
	inst.Parent = Lighting
	return inst :: any
end

local atmosphere = effect("Atmosphere", "PoolAtmosphere") :: Atmosphere
atmosphere.Density = 0.38 -- also hides chunks streaming in at the edge of view
atmosphere.Offset = 0.2
atmosphere.Color = Color3.fromRGB(214, 236, 230)
atmosphere.Decay = Color3.fromRGB(176, 214, 204)
atmosphere.Glare = 0.4
atmosphere.Haze = 1.8

local colorCorrection = effect("ColorCorrectionEffect", "PoolColor") :: ColorCorrectionEffect
colorCorrection.Brightness = 0.04
colorCorrection.Contrast = -0.08 -- flatter, softer shadows
colorCorrection.Saturation = -0.12 -- washed-out, slightly faded film look
colorCorrection.TintColor = Color3.fromRGB(244, 255, 251) -- whisper of aqua

local bloom = effect("BloomEffect", "PoolBloom") :: BloomEffect
bloom.Intensity = 0.65
bloom.Size = 40
bloom.Threshold = 0.92 -- only skylights, windows and sun glints bloom

local sunRays = effect("SunRaysEffect", "PoolSunRays") :: SunRaysEffect
sunRays.Intensity = 0.06
sunRays.Spread = 0.8

local depthOfField = effect("DepthOfFieldEffect", "PoolDreamBlur") :: DepthOfFieldEffect
depthOfField.FarIntensity = 0.18
depthOfField.FocusDistance = 28
depthOfField.InFocusRadius = 45
depthOfField.NearIntensity = 0

-- Water ------------------------------------------------------------------------------
local terrain = workspace.Terrain
terrain.WaterColor = Config.WATER_COLOR
terrain.WaterTransparency = Config.WATER_TRANSPARENCY
terrain.WaterReflectance = Config.WATER_REFLECTANCE
terrain.WaterWaveSize = Config.WATER_WAVE_SIZE
terrain.WaterWaveSpeed = Config.WATER_WAVE_SPEED

-- Sound: tiled rooms full of water should echo.
SoundService.AmbientReverb = Enum.ReverbType.Bathroom

-- Player defaults ------------------------------------------------------------------
StarterPlayer.CharacterWalkSpeed = Config.WALK_SPEED
StarterPlayer.CameraMode = Enum.CameraMode.LockFirstPerson
StarterPlayer.CameraMaxZoomDistance = 0.5
