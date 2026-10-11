--!strict
-- Right-click attack: animation only (no hitbox, damage or remote).
--
-- Input:
--   * Right mouse button is observed with UserInputService (never bound or
--     consumed), so right-drag camera turning keeps working. By default an
--     attack fires on a short, still click (CombatConfig.Attack.TriggerMode).
--     Presses over buttons/text boxes/Active UI or while typing are ignored.
--   * Gamepad R1 and an on-screen "Hit" touch button use ContextActionService.
--
-- Playback:
--   * AnimationConfig.Attack.AnimationId set and loadable: played on the
--     character's own Animator at Action priority (replicates to everyone).
--   * Otherwise: a procedural right-arm punch built by temporarily offsetting
--     the shoulder (plus elbow and waist on R15) Motor6D.C0 on top of
--     whatever the Animator is playing. The original C0 values are restored
--     when the punch ends, the character dies or despawns. This fallback is
--     only visible to the local player, because Motor6D changes made on a
--     client do not replicate; upload an animation to show it to everyone.
--   * One attack at a time: a cooldown from each start, a playing track is
--     never restarted, and a running procedural punch blocks a new one.
--
-- Sound: AudioConfig "AttackSwing" plays once per attack, at the animation's
-- "AttackImpact" event if the asset has one, otherwise SwingSoundDelay after
-- the start (custom animation) or as the procedural strike begins. There is
-- no hit sound: nothing can be hit yet, and a hit sound must only ever follow
-- a server-confirmed hit (see below).
--
-- Adding real combat later: listen for a "Hit" marker on the track
-- (GetMarkerReachedSignal) or the fallback's strike phase and FireServer an
-- AttackRequest with NO damage or target. The server must check its own
-- cooldown, that the attacker is alive, and find targets itself (spatial
-- query around the server's view of the character), as ground pounds do.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local AnimationConfig = require(Config:WaitForChild("AnimationConfig"))
local CombatConfig = require(Config:WaitForChild("CombatConfig"))
local MovementConfig = require(Config:WaitForChild("MovementConfig"))
local AttackMath = require(Shared:WaitForChild("Math"):WaitForChild("AttackMath"))
local Logger = require(Shared:WaitForChild("Utilities"):WaitForChild("Logger"))

local Client = script.Parent.Parent
local CharacterLifecycle = require(Client.Utilities.CharacterLifecycle)
local AnimationController = require(script.Parent.AnimationController)
local AudioController = require(script.Parent.AudioController)
local MovementController = require(script.Parent.MovementController)

type Context = CharacterLifecycle.Context

type JointOffset = {
	Motor: Motor6D,
	Original: CFrame,
	-- Builds the offset rotation (in the joint's Part0 space) from the pose angles.
	Rotation: (shoulderPitch: number, elbowBend: number, waistTwist: number) -> CFrame,
}

type PoseRun = {
	Context: Context,
	Joints: { JointOffset },
	Connection: RBXScriptConnection,
}

local Attack = CombatConfig.Attack
local ACTION_ATTACK = "PlatformerAttack"

local logger = Logger.new("AttackController")

local AttackController = {}

local readyAt = 0
local pressStartedAt: number? = nil
local pressDrag = 0
local poseRun: PoseRun? = nil
local activeTrack: AnimationTrack? = nil
local swingToken = 0
local swingPending = false
local warnedNoJoints: { [Context]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local started = false

------------------------------------------------------------------------------
-- Procedural fallback
------------------------------------------------------------------------------

local function findMotor(parent: Instance?, name: string): Motor6D?
	local motor = if parent then parent:FindFirstChild(name) else nil
	if motor and motor:IsA("Motor6D") then
		return motor
	end
	return nil
end

-- Rotates a joint about its own pivot by `rotation`, expressed in Part0's
-- space, independent of how the rig oriented C0 (R6 and R15 differ).
local function offsetC0(original: CFrame, rotation: CFrame): CFrame
	return CFrame.new(original.Position) * rotation * original.Rotation
end

local function collectJoints(context: Context): { JointOffset }
	local character = context.Character
	local joints: { JointOffset } = {}
	local function add(motor: Motor6D?, rotation: (number, number, number) -> CFrame)
		if motor then
			table.insert(joints, { Motor = motor, Original = motor.C0, Rotation = rotation })
		end
	end
	local function shoulderRotation(pitch: number, _: number, _: number): CFrame
		return CFrame.Angles(math.rad(pitch), 0, 0)
	end
	if context.Humanoid.RigType == Enum.HumanoidRigType.R15 then
		add(findMotor(character:FindFirstChild("RightUpperArm"), "RightShoulder"), shoulderRotation)
		add(findMotor(character:FindFirstChild("RightLowerArm"), "RightElbow"), function(_, bend, _)
			return CFrame.Angles(math.rad(bend), 0, 0)
		end)
		add(findMotor(character:FindFirstChild("UpperTorso"), "Waist"), function(_, _, twist)
			return CFrame.Angles(0, math.rad(twist), 0)
		end)
	else
		-- R6: one shoulder joint; no elbow or waist to animate.
		add(findMotor(character:FindFirstChild("Torso"), "Right Shoulder"), shoulderRotation)
	end
	return joints
end

local function stopPose()
	local run = poseRun
	poseRun = nil
	if not run then
		return
	end
	run.Connection:Disconnect()
	for _, joint in run.Joints do
		if joint.Motor.Parent ~= nil then
			joint.Motor.C0 = joint.Original
		end
	end
end

local function startPose(context: Context)
	if poseRun then
		return
	end
	local joints = collectJoints(context)
	if #joints == 0 then
		if not warnedNoJoints[context] then
			warnedNoJoints[context] = true
			logger:Warn("NoArmJoint", { Character = context.Character, Effect = "attack fallback skipped" })
		end
		return
	end
	local startedAt = os.clock()
	local connection = RunService.PreRender:Connect(function()
		local pitch, bend, twist, finished = AttackMath.FallbackPose(Attack.Fallback, os.clock() - startedAt)
		if finished or not context.Alive then
			stopPose()
			return
		end
		for _, joint in joints do
			joint.Motor.C0 = offsetC0(joint.Original, joint.Rotation(pitch, bend, twist))
		end
	end)
	poseRun = { Context = context, Joints = joints, Connection = connection }
end

------------------------------------------------------------------------------
-- Attack
------------------------------------------------------------------------------

-- Plays the swing sound once for the current attack.
local function playSwing()
	if swingPending then
		swingPending = false
		AudioController.Play("AttackSwing")
	end
end

-- Arms the swing sound: an "AttackImpact" event plays it earlier; otherwise
-- it plays after `delay`. A newer attack or stopAll supersedes it.
local function armSwing(delay: number)
	swingToken += 1
	local token = swingToken
	swingPending = true
	task.delay(delay, function()
		if swingToken == token then
			playSwing()
		end
	end)
end

local function stopAll()
	swingPending = false
	stopPose()
	local track = activeTrack
	activeTrack = nil
	if track and track.IsPlaying then
		track:Stop(0.1)
	end
	pressStartedAt = nil
end

local function tryAttack()
	if not Attack.Enabled then
		return
	end
	local context = CharacterLifecycle.GetContext()
	if not context or not context.Alive or context.Humanoid.Health <= 0 then
		return
	end
	local now = os.clock()
	if now < readyAt or poseRun ~= nil or (activeTrack and activeTrack.IsPlaying) then
		return
	end
	if Attack.BlockedStates[MovementController.GetState()] then
		return
	end
	readyAt = now + Attack.Cooldown

	local track = AnimationController.Play(context, AnimationConfig.Attack)
	if track then
		activeTrack = track
		armSwing(Attack.SwingSoundDelay)
	else
		startPose(context)
		if poseRun then
			armSwing(Attack.Fallback.WindupTime)
		end
	end
end

------------------------------------------------------------------------------
-- Input
------------------------------------------------------------------------------

local function isPointerOverInteractiveGui(position: Vector3): boolean
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return false
	end
	for _, gui in playerGui:GetGuiObjectsAtPosition(position.X, position.Y) do
		if gui.Visible and (gui.Active or gui:IsA("GuiButton") or gui:IsA("TextBox")) then
			return true
		end
	end
	return false
end

local function onInputBegan(input: InputObject, _gameProcessed: boolean)
	if input.UserInputType ~= Attack.MouseButton then
		return
	end
	pressStartedAt = nil
	if UserInputService:GetFocusedTextBox() ~= nil or isPointerOverInteractiveGui(input.Position) then
		return
	end
	if Attack.TriggerMode == "Press" then
		tryAttack()
	else
		pressStartedAt = os.clock()
		pressDrag = 0
	end
end

local function onInputChanged(input: InputObject, _gameProcessed: boolean)
	if pressStartedAt and input.UserInputType == Enum.UserInputType.MouseMovement then
		pressDrag += input.Delta.Magnitude
	end
end

local function onInputEnded(input: InputObject, _gameProcessed: boolean)
	if input.UserInputType ~= Attack.MouseButton then
		return
	end
	local startedAt = pressStartedAt
	pressStartedAt = nil
	if startedAt and AttackMath.IsClick(os.clock() - startedAt, pressDrag, Attack.ClickMaxHoldTime, Attack.ClickMaxDragPixels) then
		tryAttack()
	end
end

local function handleAttackAction(_: string, inputState: Enum.UserInputState, _: InputObject): Enum.ContextActionResult
	if inputState == Enum.UserInputState.Begin then
		tryAttack()
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------

function AttackController.Start()
	assert(not started, "AttackController already started")
	started = true

	AnimationController.Preload({ AnimationConfig.Attack.AnimationId })
	AnimationController.OnMarker("AttackImpact", function(context)
		if context == CharacterLifecycle.GetContext() then
			playSwing()
		end
	end)
	CharacterLifecycle.Register("AttackController", {
		OnSpawn = function()
			stopAll()
		end,
		OnDied = function()
			stopAll()
		end,
		OnDespawn = function()
			stopAll()
		end,
	})

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputChanged:Connect(onInputChanged)
	UserInputService.InputEnded:Connect(onInputEnded)
	ContextActionService:BindActionAtPriority(
		ACTION_ATTACK,
		handleAttackAction,
		Attack.CreateTouchButton,
		MovementConfig.Input.ActionPriority,
		Attack.GamepadButton
	)
	if Attack.CreateTouchButton then
		ContextActionService:SetTitle(ACTION_ATTACK, "Hit")
	end
end

return AttackController
