--!strict
-- CamcorderController (client): input and the look-direction stream.
--
--   F / gamepad L2 / on-screen "CAM" button  -> REQUEST raise or lower (server decides)
--   LeftShift / gamepad L3 / "RUN" button    -> REQUEST sprint while held (server decides)
--
-- The client never sets its own camcorder state, speed or battery. It follows the server's
-- Player attributes (ShutterCamcorder, ShutterBattery) and forwards camera look direction
-- while filming so the server can work out what the camcorder is pointed at.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shutter")
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))

local CAM = Config.Camcorder
local ATTR = Config.Attributes

local player = Players.LocalPlayer

type FilmingCallback = (filming: boolean) -> ()

local CamcorderController = {}

local filmingCallbacks: { FilmingCallback } = {}
local filming = false
local sprintHeld = false
local lastSprintSent = false
local lookAccumulator = 0
local savedCameraMode: Enum.CameraMode? = nil
local savedMaxZoom: number? = nil

local ACTION_CAMCORDER = "ShutterCamcorder"
local ACTION_SPRINT = "ShutterSprint"

local function serverSaysFilming(): boolean
	return player:GetAttribute(ATTR.CamcorderRaised) == true
end

local function sendSprint()
	local want = sprintHeld
	if want ~= lastSprintSent then
		lastSprintSent = want
		Net.SprintState:FireServer(want)
	end
end

local function tweenFov(target: number)
	local camera = workspace.CurrentCamera
	if camera then
		TweenService:Create(camera, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			FieldOfView = target,
		}):Play()
	end
end

local function applyCameraMode(isFilming: boolean)
	if not CAM.FORCE_FIRST_PERSON_WHILE_FILMING then
		return
	end
	if isFilming then
		if savedCameraMode == nil then
			savedCameraMode = player.CameraMode
			savedMaxZoom = player.CameraMaxZoomDistance
		end
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	else
		if savedCameraMode ~= nil then
			player.CameraMode = savedCameraMode
			if savedMaxZoom then
				player.CameraMaxZoomDistance = savedMaxZoom
			end
		end
		savedCameraMode = nil
		savedMaxZoom = nil
	end
end

local function sendLook()
	local camera = workspace.CurrentCamera
	if camera then
		Net.LookUpdate:FireServer(camera.CFrame.LookVector)
	end
end

local function onFilmingAttribute()
	local now = serverSaysFilming()
	if now == filming then
		return
	end
	filming = now
	applyCameraMode(now)
	tweenFov(if now then CAM.FILM_FIELD_OF_VIEW else CAM.NAKED_FIELD_OF_VIEW)
	if now then
		lookAccumulator = 0
		sendLook() -- the server needs a look sample right away to freeze anything
	end
	for _, callback in filmingCallbacks do
		task.spawn(callback, now)
	end
end

local function onCamcorderAction(_: string, inputState: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if inputState == Enum.UserInputState.Begin then
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			Net.CamcorderToggle:FireServer(not serverSaysFilming())
		end
	end
	return Enum.ContextActionResult.Sink
end

local function onSprintAction(_: string, inputState: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if inputState == Enum.UserInputState.Begin then
		sprintHeld = true
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		sprintHeld = false
	end
	sendSprint()
	return Enum.ContextActionResult.Pass
end

function CamcorderController.start()
	ContextActionService:BindAction(ACTION_CAMCORDER, onCamcorderAction, true, Enum.KeyCode.F, Enum.KeyCode.ButtonL2)
	ContextActionService:SetTitle(ACTION_CAMCORDER, "CAM")
	ContextActionService:SetPosition(ACTION_CAMCORDER, UDim2.new(1, -190, 1, -150))

	ContextActionService:BindAction(ACTION_SPRINT, onSprintAction, true, Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL3)
	ContextActionService:SetTitle(ACTION_SPRINT, "RUN")
	ContextActionService:SetPosition(ACTION_SPRINT, UDim2.new(1, -250, 1, -90))

	player:GetAttributeChangedSignal(ATTR.CamcorderRaised):Connect(onFilmingAttribute)
	onFilmingAttribute()

	player.CharacterAdded:Connect(function()
		-- The server resets sprint on spawn; mirror that so the next press is sent.
		sprintHeld = false
		lastSprintSent = false
	end)

	local interval = 1 / CAM.LOOK_SEND_RATE
	RunService.RenderStepped:Connect(function(dt: number)
		if not filming then
			return
		end
		lookAccumulator += dt
		if lookAccumulator >= interval then
			lookAccumulator = math.min(lookAccumulator - interval, interval)
			sendLook()
		end
	end)

	local camera = workspace.CurrentCamera
	if camera then
		camera.FieldOfView = CAM.NAKED_FIELD_OF_VIEW
	end
end

function CamcorderController.isFilming(): boolean
	return filming
end

function CamcorderController.onFilmingChanged(callback: FilmingCallback)
	table.insert(filmingCallbacks, callback)
end

return CamcorderController
