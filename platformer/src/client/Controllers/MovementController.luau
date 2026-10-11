--!strict
-- Local-player movement: double jump (with spin + float), dash (E), ground
-- pound (LeftShift), wall jump, coyote time, and their local effects.
--
-- Physics model: the client owns its character, so abilities set the root's
-- AssemblyLinearVelocity directly (instant impulses) or drive constraints
-- created once per character: a LinearVelocity (dash, wall-jump lock, pound,
-- recovery), an AngularVelocity (spin) and a VectorForce (float). All three
-- are disabled whenever no ability uses them. Ability is the single source
-- of truth for what is running; starting an ability always ends the previous
-- one first, and endAbility switches every constraint off, so nothing can
-- stack or linger. The only Humanoid property ever changed is AutoRotate,
-- turned off while spinning (so Roblox's facing logic doesn't fight the
-- spin) and restored to its saved value whenever the spin ends for any reason.
--
-- State model (Types.MovementState):
--   Dead                 character not alive
--   Dashing / GroundPounding / WallJumping / Landing / SpinFloating
--                        an ability is running
--   Grounded / Rising / Falling                        derived from physics
-- CAN_START below lists the states each ability may start from; starting
-- from an ability state interrupts it.
--
-- Per-frame work only exists while a dash, ground pound or spin-float runs (one
-- PreSimulation connection, disconnected when the ability ends). Grounded
-- transitions come from Humanoid.StateChanged events.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local GameConfig = require(Config:WaitForChild("GameConfig"))
local MovementConfig = require(Config:WaitForChild("MovementConfig"))
local AnimationConfig = require(Config:WaitForChild("AnimationConfig"))
local MovementMath = require(Shared:WaitForChild("Math"):WaitForChild("MovementMath"))
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent.Parent
local CharacterLifecycle = require(Client.Utilities.CharacterLifecycle)
local Effects = require(Client.Utilities.Effects)
local AnimationController = require(script.Parent.AnimationController)
local AudioController = require(script.Parent.AudioController)
local FeedbackController = require(script.Parent.FeedbackController)

type MovementState = Types.MovementState
type MovementAction = Types.MovementAction
type Ability = "Dash" | "GroundPound" | "WallJump" | "Recovery" | "SpinFloat"

type CharacterState = {
	Context: CharacterLifecycle.Context,
	Ability: Ability?,
	AbilityToken: number,
	AbilityStep: RBXScriptConnection?,
	AirJumpsUsed: number,
	AirDashesUsed: number,
	PoundUsedThisAir: boolean,
	LeftGroundAt: number,
	LeftGroundByJump: boolean,
	DashReadyAt: number,
	WallJumpReadyAt: number,
	LastWallPart: BasePart?,
	LastWallNormal: Vector3,
	LastWallTime: number,
	PoundId: number,
	FeetOffset: number,
	Mover: LinearVelocity,
	Spinner: AngularVelocity,
	FloatForce: VectorForce,
	-- Humanoid.AutoRotate before the spin turned it off; nil when not spinning.
	SavedAutoRotate: boolean?,
	-- Animation played by the running ability; stopped when it ends.
	AbilityTrack: AnimationTrack?,
	-- Stops the running ability's looped sound (spin air); called when it ends.
	StopAbilityLoop: (() -> ())?,
	-- A double jump happened since the last landing (for its landing accent).
	DoubleJumpedThisAir: boolean,
	Rig: Effects.CharacterRig,
	RayParams: RaycastParams,
}

local Input = MovementConfig.Input
local DoubleJump = MovementConfig.DoubleJump
local Dash = MovementConfig.Dash
local GroundPound = MovementConfig.GroundPound
local WallJump = MovementConfig.WallJump
local SpinFloat = MovementConfig.SpinFloat

local ACTION_DASH = "PlatformerDash"
local ACTION_POUND = "PlatformerGroundPound"

local ABILITY_STATE: { [Ability]: MovementState } = {
	Dash = "Dashing",
	GroundPound = "GroundPounding",
	WallJump = "WallJumping",
	Recovery = "Landing",
	SpinFloat = "SpinFloating",
}

local CAN_START: { [string]: { [MovementState]: boolean } } = {
	Dash = { Grounded = true, Rising = true, Falling = true, WallJumping = true, SpinFloating = true },
	GroundPound = { Rising = true, Falling = true, Dashing = true, WallJumping = true, SpinFloating = true },
	-- Double jump and wall jump (Dashing is handled by Dash.CancelOnJump).
	AirJump = { Rising = true, Falling = true, WallJumping = true, SpinFloating = true },
}

-- Abilities that only make sense in the air; landing ends them.
local AIR_ONLY: { [Ability]: boolean } = {
	WallJump = true,
	SpinFloat = true,
}

local GROUNDED_STATES: { [Enum.HumanoidStateType]: boolean } = {
	[Enum.HumanoidStateType.Landed] = true,
	[Enum.HumanoidStateType.Running] = true,
	[Enum.HumanoidStateType.RunningNoPhysics] = true,
	[Enum.HumanoidStateType.Climbing] = true,
	[Enum.HumanoidStateType.Swimming] = true,
	[Enum.HumanoidStateType.Seated] = true,
}

local JUMP_KEYS: { [Enum.KeyCode]: boolean } = {}
for _, key in Input.JumpKeys do
	JUMP_KEYS[key] = true
end

local MovementController = {}

local active: CharacterState? = nil
local remotes: Types.Remotes? = nil
local lastTouchJumpRequest = 0
local started = false

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------

local function report(action: MovementAction, poundId: number?)
	local remoteTable = remotes :: Types.Remotes
	if poundId then
		remoteTable.MovementAction:FireServer(action, poundId)
	else
		remoteTable.MovementAction:FireServer(action)
	end
end

local function isGrounded(state: CharacterState): boolean
	return state.Context.Humanoid.FloorMaterial ~= Enum.Material.Air
end

local function isAlive(state: CharacterState): boolean
	return state.Context.Alive and state.Context.Humanoid.Health > 0
end

local function getState(state: CharacterState): MovementState
	if not isAlive(state) then
		return "Dead"
	end
	if state.Ability then
		return ABILITY_STATE[state.Ability]
	end
	if isGrounded(state) then
		return "Grounded"
	end
	return if state.Context.RootPart.AssemblyLinearVelocity.Y > 0 then "Rising" else "Falling"
end

local function setPlaneVelocity(state: CharacterState, velocity: Vector3)
	local mover = state.Mover
	mover.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	mover.PlaneVelocity = Vector2.new(velocity.X, velocity.Z)
	mover.Enabled = true
end

local function setVectorVelocity(state: CharacterState, velocity: Vector3)
	local mover = state.Mover
	mover.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	mover.VectorVelocity = velocity
	mover.Enabled = true
end

local function stopSpin(state: CharacterState)
	state.Spinner.Enabled = false
	state.Spinner.AngularVelocity = Vector3.zero
	local saved = state.SavedAutoRotate
	if saved ~= nil then
		state.SavedAutoRotate = nil
		state.Context.Humanoid.AutoRotate = saved
	end
end

-- Stops whatever ability is running: releases its per-frame work, switches
-- every constraint off, restores AutoRotate and stops its animation.
local function endAbility(state: CharacterState)
	local step = state.AbilityStep
	state.AbilityStep = nil
	if step then
		step:Disconnect()
	end
	state.Mover.Enabled = false
	stopSpin(state)
	state.FloatForce.Enabled = false
	state.FloatForce.Force = Vector3.zero
	local track = state.AbilityTrack
	state.AbilityTrack = nil
	if track and track.IsPlaying then
		track:Stop(0.1)
	end
	local stopLoop = state.StopAbilityLoop
	state.StopAbilityLoop = nil
	if stopLoop then
		stopLoop()
	end
	state.Ability = nil
	state.AbilityToken += 1
end

local function beginAbility(state: CharacterState, ability: Ability): number
	endAbility(state)
	state.Ability = ability
	return state.AbilityToken
end

-- Ends the ability after `seconds` unless something else replaced it first.
local function endAbilityAfter(state: CharacterState, ability: Ability, seconds: number)
	local token = state.AbilityToken
	task.delay(seconds, function()
		if active == state and state.Ability == ability and state.AbilityToken == token then
			endAbility(state)
		end
	end)
end

local function humanoidJumpVelocity(humanoid: Humanoid): number
	if humanoid.UseJumpPower then
		return humanoid.JumpPower
	end
	return MovementMath.JumpVelocityFromHeight(humanoid.JumpHeight, Workspace.Gravity)
end

local function onGrounded(state: CharacterState)
	if state.DoubleJumpedThisAir and isAlive(state) then
		state.DoubleJumpedThisAir = false
		Effects.LandingPuff(state.Rig)
		AudioController.Play("DoubleJumpLanding")
	end
	state.AirJumpsUsed = 0
	state.AirDashesUsed = 0
	state.PoundUsedThisAir = false
	state.LastWallPart = nil
	if state.Ability and AIR_ONLY[state.Ability] then
		endAbility(state)
	end
end

------------------------------------------------------------------------------
-- Abilities
------------------------------------------------------------------------------

-- Spin + float after a double jump (see MovementConfig.SpinFloat for the
-- maths). Horizontal control stays with the Humanoid: the LinearVelocity is
-- off, the spin only constrains rotation, and the float only adds an upward
-- force, so steering in the air works exactly as in a normal jump.
local function startSpinFloat(state: CharacterState)
	beginAbility(state, "SpinFloat")
	local context = state.Context
	local humanoid = context.Humanoid
	local root = context.RootPart

	state.SavedAutoRotate = humanoid.AutoRotate
	humanoid.AutoRotate = false
	state.Spinner.AngularVelocity = Vector3.zero
	state.Spinner.Enabled = true
	state.FloatForce.Force = Vector3.zero
	state.FloatForce.Enabled = true
	state.AbilityTrack = AnimationController.Play(context, AnimationConfig.DoubleJumpSpin)
	AudioController.Play("SpinWhoosh")
	state.StopAbilityLoop = AudioController.StartLoop("SpinAir")

	local startedAt = os.clock()
	local totalTime = math.max(SpinFloat.SpinDuration, SpinFloat.FloatDuration)
	local peakRate = math.rad(SpinFloat.SpinSpeed) * SpinFloat.SpinDirection
	state.AbilityStep = RunService.PreSimulation:Connect(function()
		local elapsed = os.clock() - startedAt
		if elapsed >= totalTime then
			endAbility(state) -- back to a normal fall
			return
		end

		if elapsed < SpinFloat.SpinDuration then
			local rate = peakRate * MovementMath.SpinProfile(elapsed / SpinFloat.SpinDuration)
			state.Spinner.AngularVelocity = Vector3.new(0, rate, 0)
		elseif state.Spinner.Enabled then
			stopSpin(state) -- spin finished first; the float may continue
		end

		local lift = 0
		if root.AssemblyLinearVelocity.Y <= SpinFloat.FloatBelowVerticalSpeed then
			local fade = MovementMath.FloatFade(elapsed, SpinFloat.FloatDuration, SpinFloat.FloatFadeTime)
			lift = MovementMath.FloatLiftForce(root.AssemblyMass, Workspace.Gravity, SpinFloat.FallGravityScale, fade)
		end
		state.FloatForce.Force = Vector3.new(0, lift, 0)
	end)
end

local function doDoubleJump(state: CharacterState)
	if state.Ability == "WallJump" then
		endAbility(state)
	end
	local root = state.Context.RootPart
	local velocity = root.AssemblyLinearVelocity
	local upward = DoubleJump.Velocity + (if SpinFloat.Enabled then SpinFloat.UpwardBoost else 0)
	root.AssemblyLinearVelocity = Vector3.new(velocity.X, upward, velocity.Z)
	state.AirJumpsUsed += 1
	local trailTime = DoubleJump.Effects.TrailDuration
	if SpinFloat.Enabled and SpinFloat.TrailFollowsSpin then
		trailTime = math.max(trailTime, SpinFloat.SpinDuration)
	end
	Effects.DoubleJumpBurst(state.Rig, trailTime)
	AudioController.Play("DoubleJump")
	state.DoubleJumpedThisAir = true
	report("DoubleJump")
	if SpinFloat.Enabled then
		startSpinFloat(state)
	end
end

-- Closest wall within reach: rays toward the movement input first, then a
-- ring of evenly spaced horizontal directions, at each configured height.
local function findWall(state: CharacterState): RaycastResult?
	local root = state.Context.RootPart
	local directions: { Vector3 } = {}
	local move = MovementMath.FlattenDirection(state.Context.Humanoid.MoveDirection)
	if move then
		table.insert(directions, move)
	end
	local facing = MovementMath.FlattenDirection(root.CFrame.LookVector) or Vector3.new(0, 0, -1)
	for index = 0, WallJump.ProbeDirections - 1 do
		local angle = (index / WallJump.ProbeDirections) * math.pi * 2
		table.insert(directions, CFrame.Angles(0, angle, 0):VectorToWorldSpace(facing))
	end

	local best: RaycastResult? = nil
	for _, heightOffset in WallJump.ProbeHeightOffsets do
		local origin = root.Position + Vector3.new(0, heightOffset, 0)
		for _, direction in directions do
			local result = Workspace:Raycast(origin, direction * WallJump.ProbeDistance, state.RayParams)
			if
				result
				and MovementMath.IsWallNormal(result.Normal, WallJump.MaxWallNormalY)
				and (best == nil or result.Distance < best.Distance)
			then
				best = result
			end
		end
	end
	return best
end

local function tryWallJump(state: CharacterState, now: number): boolean
	if now < state.WallJumpReadyAt then
		return false
	end
	local hit = findWall(state)
	if not hit then
		return false
	end
	local wall = hit.Instance
	if
		state.LastWallPart == wall
		and state.LastWallNormal:Dot(hit.Normal) >= WallJump.SameWallNormalDot
		and now - state.LastWallTime < WallJump.SameWallCooldown
	then
		return false
	end

	local launch =
		MovementMath.WallJumpVelocity(hit.Normal, WallJump.HorizontalWeight, WallJump.VerticalWeight, WallJump.LaunchSpeed)
	if WallJump.InheritWallVelocity then
		local wallVelocity = wall.AssemblyLinearVelocity
		launch += Vector3.new(wallVelocity.X, 0, wallVelocity.Z)
	end

	beginAbility(state, "WallJump")
	local root = state.Context.RootPart
	root.AssemblyLinearVelocity = launch
	local away = MovementMath.FlattenDirection(launch)
	if WallJump.FaceAwayFromWall and away then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + away)
	end
	-- Hold the horizontal launch briefly so steering can't cancel it.
	setPlaneVelocity(state, launch)
	endAbilityAfter(state, "WallJump", WallJump.ControlLockTime)

	state.WallJumpReadyAt = now + WallJump.Cooldown
	state.LastWallPart = wall
	state.LastWallNormal = hit.Normal
	state.LastWallTime = now
	if WallJump.RestoresDoubleJump then
		state.AirJumpsUsed = 0
	end
	Effects.DoubleJumpBurst(state.Rig)
	AudioController.Play("WallJump")
	report("WallJump")
	return true
end

local function tryDash(state: CharacterState): boolean
	if not Dash.Enabled then
		return false
	end
	local now = os.clock()
	if now < state.DashReadyAt or not CAN_START.Dash[getState(state)] then
		return false
	end
	local grounded = isGrounded(state)
	if grounded and not Dash.AllowOnGround then
		return false
	end
	if not grounded and (not Dash.AllowInAir or state.AirDashesUsed >= Dash.MaxAirDashes) then
		return false
	end

	local root = state.Context.RootPart
	local direction = MovementMath.ResolveDashDirection(state.Context.Humanoid.MoveDirection, root.CFrame.LookVector)
	beginAbility(state, "Dash")
	if not grounded then
		state.AirDashesUsed += 1
		local velocity = root.AssemblyLinearVelocity
		if Dash.ResetFallSpeedInAir and velocity.Y < 0 then
			root.AssemblyLinearVelocity = Vector3.new(velocity.X, 0, velocity.Z)
		end
	end
	root.CFrame = CFrame.lookAt(root.Position, root.Position + direction)
	state.DashReadyAt = now + Dash.Cooldown
	setPlaneVelocity(state, direction * Dash.InitialSpeed)
	state.AbilityTrack = AnimationController.Play(state.Context, AnimationConfig.DashRoll)
	Effects.DashBurst(state.Rig, Dash.Duration)
	AudioController.Play("Dash")
	report("Dash")

	state.AbilityStep = RunService.PreSimulation:Connect(function()
		local progress = (os.clock() - now) / Dash.Duration
		if progress >= 1 then
			endAbility(state)
			return
		end
		setPlaneVelocity(state, direction * MovementMath.DashSpeed(Dash.InitialSpeed, Dash.TerminalSpeed, Dash.Curve, progress))
	end)
	return true
end

local function landPound(state: CharacterState, poundId: number, groundPosition: Vector3)
	endAbility(state)
	local root = state.Context.RootPart
	-- Snap the last few studs the probe saw ahead, so the impact lands on the frame it shows.
	local gap = (root.Position.Y - state.FeetOffset) - groundPosition.Y
	if gap > 0 then
		root.CFrame -= Vector3.new(0, gap, 0)
	end
	root.AssemblyLinearVelocity = Vector3.zero

	local remoteTable = remotes :: Types.Remotes
	remoteTable.GroundPoundImpact:FireServer(poundId, groundPosition)
	Effects.Shockwave(groundPosition, GroundPound.Shockwave.Radius)
	Effects.ImpactBurst(groundPosition)
	AudioController.PlayAt("GroundPoundImpact", groundPosition)
	FeedbackController.AddTrauma(GroundPound.CameraShakeTrauma)

	beginAbility(state, "Recovery")
	setPlaneVelocity(state, Vector3.zero)
	endAbilityAfter(state, "Recovery", GroundPound.RecoveryTime)
end

local function tryGroundPound(state: CharacterState): boolean
	if not GroundPound.Enabled or state.PoundUsedThisAir or isGrounded(state) then
		return false
	end
	if not CAN_START.GroundPound[getState(state)] then
		return false
	end
	local root = state.Context.RootPart
	local clearance = state.FeetOffset + GroundPound.MinActivationHeight
	if Workspace:Raycast(root.Position, Vector3.new(0, -clearance, 0), state.RayParams) then
		return false -- too close to the ground
	end

	beginAbility(state, "GroundPound") -- interrupts a dash or wall jump
	state.PoundUsedThisAir = true
	state.DoubleJumpedThisAir = false -- the pound impact is this landing's sound
	AudioController.Play("GroundPoundStart")
	state.PoundId += 1
	local poundId = state.PoundId
	report("GroundPoundStart", poundId)
	setVectorVelocity(state, Vector3.zero)

	local startedAt = os.clock()
	state.AbilityStep = RunService.PreSimulation:Connect(function(deltaTime: number)
		local elapsed = os.clock() - startedAt
		if elapsed < GroundPound.WindupTime then
			setVectorVelocity(state, Vector3.zero)
			return
		end
		local descent = elapsed - GroundPound.WindupTime
		if descent > GroundPound.MaxDescentTime then
			endAbility(state) -- nothing below: cancel without an impact
			return
		end
		local speed = MovementMath.DescentSpeed(
			GroundPound.InitialDescentSpeed,
			GroundPound.DescentAcceleration,
			GroundPound.MaxDescentSpeed,
			descent
		)
		setVectorVelocity(state, Vector3.new(0, -speed, 0))

		local probe = state.FeetOffset + speed * deltaTime + GroundPound.LandingProbeMargin
		local hit = Workspace:Raycast(root.Position, Vector3.new(0, -probe, 0), state.RayParams)
		if hit then
			landPound(state, poundId, hit.Position)
		elseif descent > 0.05 and isGrounded(state) then
			-- Steep or thin surfaces the ray missed but the Humanoid stands on.
			landPound(state, poundId, root.Position - Vector3.new(0, state.FeetOffset, 0))
		end
	end)
	return true
end

------------------------------------------------------------------------------
-- Input
------------------------------------------------------------------------------

local function onJumpPressed()
	local state = active
	if not state or not isAlive(state) then
		return
	end
	if state.Ability == "Dash" then
		if not Dash.CancelOnJump then
			return
		end
		endAbility(state)
	end
	if isGrounded(state) then
		return -- Roblox's own jump handles ground jumps
	end
	if not CAN_START.AirJump[getState(state)] then
		return
	end

	local now = os.clock()
	if not state.LeftGroundByJump and state.AirJumpsUsed == 0 and now - state.LeftGroundAt <= MovementConfig.Grounding.CoyoteTime then
		local root = state.Context.RootPart
		local velocity = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(velocity.X, humanoidJumpVelocity(state.Context.Humanoid), velocity.Z)
		state.LeftGroundByJump = true
		return
	end
	if WallJump.Enabled and tryWallJump(state, now) then
		return
	end
	if DoubleJump.Enabled and state.AirJumpsUsed < DoubleJump.MaxAirJumps then
		doDoubleJump(state)
	end
end

-- Keyboard/gamepad jump presses are observed with InputBegan, which never
-- consumes input, so Roblox's own jump binding is untouched. gameProcessed
-- cannot filter here (it is true for Space because the default controls bind
-- it through ContextActionService), so typing in a TextBox is excluded instead.
local function onInputBegan(input: InputObject, _gameProcessed: boolean)
	if JUMP_KEYS[input.KeyCode] and UserInputService:GetFocusedTextBox() == nil then
		onJumpPressed()
	end
end

local function handleDashAction(_: string, inputState: Enum.UserInputState, _: InputObject): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin or not active then
		return Enum.ContextActionResult.Pass
	end
	return if tryDash(active) then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
end

local function handlePoundAction(_: string, inputState: Enum.UserInputState, _: InputObject): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin or not active then
		return Enum.ContextActionResult.Pass
	end
	return if tryGroundPound(active) then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
end

-- Touch jump arrives as JumpRequest; edge-detect it by the silence between requests.
local function onJumpRequest()
	if UserInputService:GetLastInputType() ~= Enum.UserInputType.Touch then
		return
	end
	local now = os.clock()
	local isNewPress = now - lastTouchJumpRequest > Input.TouchJumpRepeatWindow
	lastTouchJumpRequest = now
	if isNewPress then
		onJumpPressed()
	end
end

------------------------------------------------------------------------------
-- Character lifecycle
------------------------------------------------------------------------------

local function onSpawn(context: CharacterLifecycle.Context)
	local humanoid = context.Humanoid
	local root = context.RootPart
	local leg = context.Character:FindFirstChild("Left Leg")
	local feetOffset = MovementMath.FeetOffset(
		humanoid.RigType == Enum.HumanoidRigType.R15,
		humanoid.HipHeight,
		root.Size.Y,
		if leg and leg:IsA("BasePart") then leg.Size.Y else 2
	)

	local attachment = context.Cleanup:Add(Instance.new("Attachment"))
	attachment.Name = "PlatformerMover"
	attachment.Parent = root
	local mover = context.Cleanup:Add(Instance.new("LinearVelocity"))
	mover.Name = "PlatformerMover"
	mover.Attachment0 = attachment
	mover.RelativeTo = Enum.ActuatorRelativeTo.World
	mover.MaxForce = MovementConfig.Physics.ConstraintMaxForce
	mover.PrimaryTangentAxis = Vector3.xAxis
	mover.SecondaryTangentAxis = Vector3.zAxis
	mover.Enabled = false
	mover.Parent = root

	local spinner = context.Cleanup:Add(Instance.new("AngularVelocity"))
	spinner.Name = "PlatformerSpin"
	spinner.Attachment0 = attachment
	spinner.RelativeTo = Enum.ActuatorRelativeTo.World
	spinner.MaxTorque = SpinFloat.MaxTorque
	spinner.ReactionTorqueEnabled = false
	spinner.Enabled = false
	spinner.Parent = root

	local floatForce = context.Cleanup:Add(Instance.new("VectorForce"))
	floatForce.Name = "PlatformerFloat"
	floatForce.Attachment0 = attachment
	floatForce.RelativeTo = Enum.ActuatorRelativeTo.World
	floatForce.ApplyAtCenterOfMass = true
	floatForce.Force = Vector3.zero
	floatForce.Enabled = false
	floatForce.Parent = root

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { context.Character }
	rayParams.RespectCanCollide = true
	-- Same rules as the character's physics: ignores client debris chunks.
	rayParams.CollisionGroup = GameConfig.CollisionGroups.Characters

	local state: CharacterState = {
		Context = context,
		Ability = nil,
		AbilityToken = 0,
		AbilityStep = nil,
		AirJumpsUsed = 0,
		AirDashesUsed = 0,
		PoundUsedThisAir = false,
		LeftGroundAt = -math.huge,
		LeftGroundByJump = true,
		DashReadyAt = 0,
		WallJumpReadyAt = 0,
		LastWallPart = nil,
		LastWallNormal = Vector3.zero,
		LastWallTime = -math.huge,
		PoundId = 0,
		FeetOffset = feetOffset,
		Mover = mover,
		Spinner = spinner,
		FloatForce = floatForce,
		SavedAutoRotate = nil,
		AbilityTrack = nil,
		StopAbilityLoop = nil,
		DoubleJumpedThisAir = false,
		Rig = Effects.CreateCharacterRig(root, feetOffset, context.Cleanup),
		RayParams = rayParams,
	}

	context.Cleanup:Connect(humanoid.StateChanged, function(old: Enum.HumanoidStateType, new: Enum.HumanoidStateType)
		if GROUNDED_STATES[new] then
			onGrounded(state)
		elseif new == Enum.HumanoidStateType.Jumping then
			state.LeftGroundAt = os.clock()
			state.LeftGroundByJump = true
		elseif new == Enum.HumanoidStateType.Freefall and GROUNDED_STATES[old] then
			state.LeftGroundAt = os.clock()
			state.LeftGroundByJump = false
		end
	end)

	active = state
end

local function onDied(context: CharacterLifecycle.Context)
	local state = active
	if state and state.Context == context then
		endAbility(state)
	end
end

local function onDespawn(context: CharacterLifecycle.Context)
	local state = active
	if state and state.Context == context then
		endAbility(state)
		active = nil
	end
end

local function onImpactEffect(effect: any)
	if type(effect) ~= "table" or typeof(effect.Position) ~= "Vector3" or type(effect.Radius) ~= "number" then
		return
	end
	if effect.SourceUserId ~= Players.LocalPlayer.UserId then
		-- Our own impact was already shown and heard when it happened.
		Effects.Shockwave(effect.Position, effect.Radius)
		Effects.ImpactBurst(effect.Position)
		AudioController.PlayAt("GroundPoundImpact", effect.Position)
	end
	if type(effect.Broken) == "table" then
		local broken: { Types.BrokenPartInfo } = {}
		for _, info in effect.Broken do
			if
				type(info) == "table"
				and typeof(info.CFrame) == "CFrame"
				and typeof(info.Size) == "Vector3"
				and typeof(info.Color) == "Color3"
				and typeof(info.Material) == "EnumItem"
			then
				table.insert(broken, info)
			end
		end
		Effects.DebrisChunks(broken)
	end
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

function MovementController.GetState(): MovementState
	local state = active
	return if state then getState(state) else "Dead"
end

function MovementController.Init(remoteTable: Types.Remotes)
	remotes = remoteTable
end

function MovementController.Start()
	assert(not started, "MovementController already started")
	assert(remotes, "MovementController.Init must run before Start")
	started = true

	AnimationController.Preload({ AnimationConfig.DashRoll.AnimationId, AnimationConfig.DoubleJumpSpin.AnimationId })
	CharacterLifecycle.Register("MovementController", {
		OnSpawn = onSpawn,
		OnDied = onDied,
		OnDespawn = onDespawn,
	})

	UserInputService.InputBegan:Connect(onInputBegan)
	ContextActionService:BindActionAtPriority(
		ACTION_DASH,
		handleDashAction,
		Input.CreateTouchButtons,
		Input.ActionPriority,
		table.unpack(Input.DashKeys)
	)
	ContextActionService:BindActionAtPriority(
		ACTION_POUND,
		handlePoundAction,
		Input.CreateTouchButtons,
		Input.ActionPriority,
		table.unpack(Input.GroundPoundKeys)
	)
	if Input.CreateTouchButtons then
		ContextActionService:SetTitle(ACTION_DASH, "Dash")
		ContextActionService:SetTitle(ACTION_POUND, "Pound")
	end
	UserInputService.JumpRequest:Connect(onJumpRequest)
	;(remotes :: Types.Remotes).ImpactEffect.OnClientEvent:Connect(onImpactEffect)
end

return MovementController
