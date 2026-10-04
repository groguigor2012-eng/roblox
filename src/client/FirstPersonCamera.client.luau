--!strict
-- Locked first-person view with a soft, smoothed head-bob.
--
-- The bob is applied AFTER Roblox's camera has updated each frame (render priority
-- Camera + 1). It only offsets the camera vertically/sideways and rolls it around
-- the view axis, so it never changes where you are looking and never accumulates.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Poolrooms"):WaitForChild("Config"))

local player = Players.LocalPlayer
player.CameraMode = Enum.CameraMode.LockFirstPerson
player.CameraMaxZoomDistance = 0.5

local camera = workspace.CurrentCamera
camera.FieldOfView = Config.FIELD_OF_VIEW

-- Tuning
local WALK_CYCLE = 7.2 -- radians per second of the step cycle at full walk speed
local SWIM_CYCLE = 2.4
local BOB_HEIGHT = 0.09 -- studs, vertical bounce per step
local BOB_SWAY = 0.05 -- studs, side-to-side per stride
local BOB_ROLL = math.rad(0.35)
local SWIM_HEIGHT = 0.16 -- slower, deeper float while swimming
local IDLE_BREATH = 0.015 -- studs, barely-there breathing when standing still
local SMOOTHING = 6 -- how fast the bob fades in/out

local phase = 0
local strength = 0
local swimBlend = 0

RunService:BindToRenderStep("PoolroomsHeadBob", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart or not rootPart:IsA("BasePart") or humanoid.Health <= 0 then
		return
	end

	local velocity = rootPart.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local swimming = humanoid:GetState() == Enum.HumanoidStateType.Swimming
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air

	local target = 0
	if speed > 0.5 and (grounded or swimming) then
		target = math.clamp(speed / Config.WALK_SPEED, 0, 1.25)
	end
	local blend = math.min(1, dt * SMOOTHING)
	strength += (target - strength) * blend
	swimBlend += ((if swimming then 1 else 0) - swimBlend) * blend

	local cycle = WALK_CYCLE + (SWIM_CYCLE - WALK_CYCLE) * swimBlend
	phase = (phase + dt * cycle * math.max(strength, 0.15)) % (math.pi * 4)

	-- Walking: two bounces per stride, one sway. Swimming: one slow rise and fall.
	local walkY = math.sin(phase * 2) * BOB_HEIGHT
	local swimY = math.sin(phase) * SWIM_HEIGHT
	local y = (walkY + (swimY - walkY) * swimBlend) * strength
	local x = math.sin(phase) * BOB_SWAY * strength * (1 - swimBlend)
	local roll = math.sin(phase) * BOB_ROLL * strength
	y += math.sin(os.clock() * 1.3) * IDLE_BREATH

	camera.CFrame = camera.CFrame * CFrame.new(x, y, 0) * CFrame.Angles(0, 0, roll)
end)
