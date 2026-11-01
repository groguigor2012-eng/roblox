--!strict
-- CamcorderService (server): the authority for camcorder state, battery and movement speed.
--
-- * Clients only REQUEST to raise/lower the camcorder or to sprint. The server decides.
-- * Battery drains/recharges here, on the server clock. Clients see it as a Player attribute.
-- * Humanoid.WalkSpeed is set here, and a position-sampling check rubber-bands clients that
--   move faster than the server allows (clients own their character's physics).
-- * The client's look direction is accepted only as a unit vector, rate-limited, checked
--   against the character's facing, and stamped with server time. The origin is always the
--   server's own copy of the head position.
--
-- Other server systems use the public API at the bottom (isFilming, getLook, ...).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shutter")
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))

local CAM = Config.Camcorder
local MOVE = Config.Movement
local ATTR = Config.Attributes

export type PlayerState = {
	player: Player,
	battery: number,
	raised: boolean,
	sprintRequested: boolean,
	loweredAt: number,
	lastToggleAt: number,
	-- look
	lookDirection: Vector3?,
	lookTime: number,
	lookTokens: number,
	-- sprint rate limit
	sprintTokens: number,
	-- replication
	lastBatterySent: number,
	lastBatterySentAt: number,
	-- anti-speed
	lastSamplePosition: Vector3?,
	lastSampleAt: number,
	lastValidCFrame: CFrame?,
	strikes: number,
	ignoreSpeedUntil: number,
	previousAllowedSpeed: number,
	-- character
	humanoid: Humanoid?,
	rootPart: BasePart?,
	head: BasePart?,
	characterConnections: { RBXScriptConnection },
}

type ChangedCallback = (player: Player, raised: boolean, reason: string) -> ()

local CamcorderService = {}

local states: { [Player]: PlayerState } = {}
local changedCallbacks: { ChangedCallback } = {}
local started = false

-- Helpers ----------------------------------------------------------------------------------

local function isFiniteVector(v: Vector3): boolean
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z and math.abs(v.X) < 1e6 and math.abs(v.Y) < 1e6 and math.abs(v.Z) < 1e6
end

local function isAlive(state: PlayerState): boolean
	local humanoid = state.humanoid
	return humanoid ~= nil and humanoid.Health > 0 and humanoid.Parent ~= nil and state.rootPart ~= nil
end

local function horizontal(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function pushBattery(state: PlayerState, force: boolean)
	local now = os.clock()
	local value = math.floor(state.battery * 10 + 0.5) / 10
	if not force then
		if value == state.lastBatterySent then
			return
		end
		local atEdge = value <= 0 or value >= CAM.MAX_BATTERY
		if not atEdge and now - state.lastBatterySentAt < CAM.BATTERY_REPLICATE_INTERVAL then
			return
		end
	end
	state.lastBatterySent = value
	state.lastBatterySentAt = now
	state.player:SetAttribute(ATTR.Battery, value)
end

local function allowedSpeed(state: PlayerState): number
	if state.raised then
		return MOVE.CAMCORDER_SPEED
	elseif state.sprintRequested then
		return MOVE.SPRINT_SPEED
	end
	return MOVE.WALK_SPEED
end

local function applySpeed(state: PlayerState)
	local humanoid = state.humanoid
	if not humanoid then
		return
	end
	local speed = allowedSpeed(state)
	if humanoid.WalkSpeed ~= speed then
		humanoid.WalkSpeed = speed
	end
	local sprinting = state.sprintRequested and not state.raised
	if state.player:GetAttribute(ATTR.Sprinting) ~= sprinting then
		state.player:SetAttribute(ATTR.Sprinting, sprinting)
	end
end

local function setRaised(state: PlayerState, raised: boolean, reason: string)
	if state.raised == raised then
		return
	end
	state.raised = raised
	if not raised then
		state.loweredAt = os.clock()
		state.lookDirection = nil
	end
	-- Speed changes take a moment to show up in replicated movement; don't flag that.
	state.ignoreSpeedUntil = os.clock() + 0.6
	state.player:SetAttribute(ATTR.CamcorderRaised, raised)
	applySpeed(state)
	pushBattery(state, true)
	for _, callback in changedCallbacks do
		task.spawn(callback, state.player, raised, reason)
	end
end

-- Character lifecycle ------------------------------------------------------------------------

local function disconnectCharacter(state: PlayerState)
	for _, connection in state.characterConnections do
		connection:Disconnect()
	end
	table.clear(state.characterConnections)
	state.humanoid = nil
	state.rootPart = nil
	state.head = nil
end

local function onCharacterAdded(state: PlayerState, character: Model)
	disconnectCharacter(state)
	setRaised(state, false, "respawn")
	state.sprintRequested = false
	if CAM.RESET_BATTERY_ON_SPAWN then
		state.battery = CAM.MAX_BATTERY
	end

	local humanoid = character:WaitForChild("Humanoid", 10)
	local rootPart = character:WaitForChild("HumanoidRootPart", 10)
	local head = character:WaitForChild("Head", 10)
	if state.player.Character ~= character then
		return -- respawned again while we waited
	end
	if not humanoid or not humanoid:IsA("Humanoid") then
		warn(`[Shutter] {state.player.Name}'s character has no Humanoid`)
		return
	end
	if not rootPart or not rootPart:IsA("BasePart") then
		warn(`[Shutter] {state.player.Name}'s character has no HumanoidRootPart`)
		return
	end
	state.humanoid = humanoid
	state.rootPart = rootPart
	state.head = if head and head:IsA("BasePart") then head else nil
	state.lastSamplePosition = rootPart.Position
	state.lastSampleAt = os.clock()
	state.lastValidCFrame = rootPart.CFrame
	state.strikes = 0
	state.ignoreSpeedUntil = os.clock() + 2

	table.insert(
		state.characterConnections,
		humanoid.Died:Connect(function()
			setRaised(state, false, "died")
			state.sprintRequested = false
		end)
	)
	-- If anything else rewrites WalkSpeed on the server, put it back.
	table.insert(
		state.characterConnections,
		humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
			applySpeed(state)
		end)
	)
	applySpeed(state)
	pushBattery(state, true)
end

local function onPlayerAdded(player: Player)
	local now = os.clock()
	local state: PlayerState = {
		player = player,
		battery = CAM.MAX_BATTERY,
		raised = false,
		sprintRequested = false,
		loweredAt = now - CAM.RECHARGE_DELAY,
		lastToggleAt = 0,
		lookDirection = nil,
		lookTime = 0,
		lookTokens = CAM.LOOK_MAX_RATE,
		sprintTokens = MOVE.SPRINT_REQUEST_RATE,
		lastBatterySent = -1,
		lastBatterySentAt = 0,
		lastSamplePosition = nil,
		lastSampleAt = now,
		lastValidCFrame = nil,
		strikes = 0,
		ignoreSpeedUntil = 0,
		previousAllowedSpeed = MOVE.WALK_SPEED,
		humanoid = nil,
		rootPart = nil,
		head = nil,
		characterConnections = {},
	}
	states[player] = state
	player:SetAttribute(ATTR.CamcorderRaised, false)
	player:SetAttribute(ATTR.Sprinting, false)
	player:SetAttribute(ATTR.Clues, player:GetAttribute(ATTR.Clues) or 0)
	pushBattery(state, true)

	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(state, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, state, player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	local state = states[player]
	if state then
		disconnectCharacter(state)
		states[player] = nil
	end
end

-- Remote handlers (every argument is untrusted) ---------------------------------------------

local function onToggleRequest(player: Player, wantRaised: unknown)
	if typeof(wantRaised) ~= "boolean" then
		return
	end
	local state = states[player]
	if not state or state.raised == wantRaised then
		return
	end
	local now = os.clock()
	if now - state.lastToggleAt < CAM.TOGGLE_COOLDOWN then
		return
	end
	if wantRaised then
		if not isAlive(state) or state.battery < CAM.MIN_BATTERY_TO_RAISE then
			return
		end
	end
	state.lastToggleAt = now
	setRaised(state, wantRaised, "request")
end

local function onSprintRequest(player: Player, wantSprint: unknown)
	if typeof(wantSprint) ~= "boolean" then
		return
	end
	local state = states[player]
	if not state or state.sprintTokens < 1 then
		return
	end
	state.sprintTokens -= 1
	if not isAlive(state) then
		wantSprint = false
	end
	if state.sprintRequested ~= wantSprint then
		state.sprintRequested = wantSprint
		state.ignoreSpeedUntil = os.clock() + 0.6
		applySpeed(state)
	end
end

local function onLookUpdate(player: Player, direction: unknown)
	local state = states[player]
	if not state or not state.raised then
		return -- looks only matter while filming
	end
	if state.lookTokens < 1 then
		return
	end
	state.lookTokens -= 1
	if typeof(direction) ~= "Vector3" or not isFiniteVector(direction) then
		return
	end
	local magnitude = direction.Magnitude
	if magnitude < 0.9 or magnitude > 1.1 then
		return
	end
	local unit = direction / magnitude
	local rootPart = state.rootPart
	if not rootPart then
		return
	end
	-- While filming the camera is first person, so the body yaw follows the camera.
	-- A look far from where the body faces is a forged packet (or extreme lag): drop it.
	local flatLook = horizontal(unit)
	local flatBody = horizontal(rootPart.CFrame.LookVector)
	if flatLook.Magnitude > 0.2 and flatBody.Magnitude > 0.2 then
		local dot = math.clamp(flatLook.Unit:Dot(flatBody.Unit), -1, 1)
		if math.deg(math.acos(dot)) > CAM.LOOK_MAX_BODY_YAW then
			return
		end
	end
	state.lookDirection = unit
	state.lookTime = os.clock()
end

-- Simulation -----------------------------------------------------------------------------------

local function checkSpeed(state: PlayerState, now: number)
	if not MOVE.ANTI_SPEED_ENABLED then
		return
	end
	local rootPart = state.rootPart
	local humanoid = state.humanoid
	if not rootPart or not humanoid or humanoid.Health <= 0 then
		return
	end
	local elapsed = now - state.lastSampleAt
	if elapsed < MOVE.ANTI_SPEED_INTERVAL then
		return
	end
	local position = rootPart.Position
	local allowed = math.max(allowedSpeed(state), state.previousAllowedSpeed)
	state.previousAllowedSpeed = allowedSpeed(state)

	local last = state.lastSamplePosition
	state.lastSamplePosition = position
	state.lastSampleAt = now
	if not last then
		state.lastValidCFrame = rootPart.CFrame
		return
	end
	if now < state.ignoreSpeedUntil or humanoid.SeatPart ~= nil then
		state.lastValidCFrame = rootPart.CFrame
		state.strikes = 0
		return
	end

	local travelled = horizontal(position - last).Magnitude
	local limit = allowed * elapsed * MOVE.ANTI_SPEED_TOLERANCE + MOVE.ANTI_SPEED_SLACK
	if travelled > limit then
		state.strikes += 1
		if state.strikes >= MOVE.ANTI_SPEED_STRIKES then
			local valid = state.lastValidCFrame
			if valid then
				local character = state.player.Character
				if character then
					character:PivotTo(valid)
				end
				state.lastSamplePosition = valid.Position
			end
			state.strikes = 0
			state.ignoreSpeedUntil = now + 0.5
		end
	else
		state.strikes = math.max(0, state.strikes - 1)
		if state.strikes == 0 then
			state.lastValidCFrame = rootPart.CFrame
		end
	end
end

local function step(dt: number)
	local now = os.clock()
	for _, state in states do
		-- Refill rate-limit buckets.
		state.lookTokens = math.min(CAM.LOOK_MAX_RATE, state.lookTokens + CAM.LOOK_MAX_RATE * dt)
		state.sprintTokens = math.min(MOVE.SPRINT_REQUEST_RATE, state.sprintTokens + MOVE.SPRINT_REQUEST_RATE * dt)

		if state.raised then
			state.battery = math.max(0, state.battery - CAM.DRAIN_PER_SECOND * dt)
			if state.battery <= 0 then
				setRaised(state, false, "battery")
			elseif not isAlive(state) then
				setRaised(state, false, "died")
			end
		elseif now - state.loweredAt >= CAM.RECHARGE_DELAY and state.battery < CAM.MAX_BATTERY then
			state.battery = math.min(CAM.MAX_BATTERY, state.battery + CAM.RECHARGE_PER_SECOND * dt)
		end
		pushBattery(state, false)
		checkSpeed(state, now)
	end
end

-- Public API -------------------------------------------------------------------------------------

function CamcorderService.start()
	if started then
		return
	end
	started = true
	Net.CamcorderToggle.OnServerEvent:Connect(onToggleRequest)
	Net.SprintState.OnServerEvent:Connect(onSprintRequest)
	Net.LookUpdate.OnServerEvent:Connect(onLookUpdate)
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	RunService.Heartbeat:Connect(step)
end

function CamcorderService.getState(player: Player): PlayerState?
	return states[player]
end

-- True while the camcorder is up, has charge, and the player is alive.
function CamcorderService.isFilming(player: Player): boolean
	local state = states[player]
	return state ~= nil and state.raised and state.battery > 0 and isAlive(state)
end

-- Returns (eye position from the SERVER's head copy, fresh look direction) while filming.
function CamcorderService.getLook(player: Player): (Vector3?, Vector3?)
	local state = states[player]
	if not state or not CamcorderService.isFilming(player) then
		return nil, nil
	end
	local direction = state.lookDirection
	if not direction or os.clock() - state.lookTime > CAM.LOOK_MAX_AGE then
		return nil, nil
	end
	local head = state.head
	local rootPart = state.rootPart
	local origin: Vector3
	if head and head.Parent then
		origin = head.Position
	elseif rootPart then
		origin = rootPart.Position + Vector3.new(0, 1.5, 0)
	else
		return nil, nil
	end
	return origin, direction
end

function CamcorderService.getBattery(player: Player): number
	local state = states[player]
	return if state then state.battery else 0
end

function CamcorderService.addBattery(player: Player, amount: number)
	local state = states[player]
	if not state or amount ~= amount then
		return
	end
	state.battery = math.clamp(state.battery + amount, 0, CAM.MAX_BATTERY)
	if state.battery <= 0 then
		setRaised(state, false, "battery")
	end
	pushBattery(state, true)
end

function CamcorderService.forceLower(player: Player, reason: string?)
	local state = states[player]
	if state then
		setRaised(state, false, reason or "forced")
	end
end

-- Call before the server teleports a character, so the speed check doesn't rubber-band it.
function CamcorderService.allowTeleport(player: Player, seconds: number?)
	local state = states[player]
	if state then
		state.ignoreSpeedUntil = os.clock() + (seconds or 1)
		state.lastSamplePosition = nil
	end
end

-- Subscribe to raise/lower. Returns a function that unsubscribes.
function CamcorderService.onCamcorderChanged(callback: ChangedCallback): () -> ()
	table.insert(changedCallbacks, callback)
	return function()
		local index = table.find(changedCallbacks, callback)
		if index then
			table.remove(changedCallbacks, index)
		end
	end
end

return CamcorderService
