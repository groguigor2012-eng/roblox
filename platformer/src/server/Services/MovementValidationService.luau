--!strict
-- Server-side checks for client-simulated movement.
--
-- What is and is not authoritative:
--   * Character physics (double jump, dash, wall jump, pound descent) runs on
--     the owning client, which has network ownership of its character. The
--     server does not re-simulate it. It records reported actions, enforces
--     cooldowns and rates, and keeps a violation score (logged, optionally kicked).
--   * World changes ARE authoritative: a ground pound only breaks anything if
--     the server registered its start (character alive, server-observed root
--     high enough above ground) and the impact passes timing, distance,
--     drift, height and ground checks against the server's own view of the
--     character. The server then picks the impact point and the parts.
--
-- Tolerances deliberately widen with ping and use the configured top speeds,
-- because high-velocity abilities are the point of a platformer; a fixed
-- "moved too far" threshold would reject legitimate play.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local MovementConfig = require(Shared.Config.MovementConfig)
local MovementMath = require(Shared.Math.MovementMath)
local Logger = require(Shared.Utilities.Logger)
local Types = require(Shared.Types)

local RateLimiter = require(script.Parent.Parent.Utilities.RateLimiter)
local CharacterService = require(script.Parent.CharacterService)
local DestructibleService = require(script.Parent.DestructibleService)

type MovementAction = Types.MovementAction

type PoundState = {
	Id: number,
	StartedAt: number,
	StartRootPosition: Vector3,
	FeetOffset: number,
	Processed: boolean,
}

type PlayerState = {
	LastAction: { [string]: number },
	Pound: PoundState?,
	LastPoundId: number,
	Violations: number,
	ViolationUpdatedAt: number,
}

local Validation = MovementConfig.Validation
local GroundPound = MovementConfig.GroundPound

-- Highest pound id accepted above the last one (guards against huge jumps).
local MAX_POUND_ID_STEP = 1000

local ACTION_ENABLED: { [string]: boolean } = {
	DoubleJump = MovementConfig.DoubleJump.Enabled,
	Dash = MovementConfig.Dash.Enabled,
	GroundPoundStart = GroundPound.Enabled,
	WallJump = MovementConfig.WallJump.Enabled,
}

-- Minimum server-side spacing between two reports of the same action.
local MIN_INTERVAL: { [string]: number } = {
	DoubleJump = Validation.DoubleJumpMinInterval,
	Dash = math.max(0, MovementConfig.Dash.Cooldown - Validation.CooldownTolerance),
	GroundPoundStart = 0, -- pound-specific checks below
	WallJump = math.max(0, MovementConfig.WallJump.Cooldown - Validation.CooldownTolerance),
}

local logger = Logger.new("MovementValidation")

local MovementValidationService = {}

local states: { [Player]: PlayerState } = {}
local limiter = RateLimiter.new(Validation.RateCapacity, Validation.RateRefillPerSecond)
local remotes: Types.Remotes? = nil
local started = false

local function getState(player: Player): PlayerState
	local state = states[player]
	if not state then
		state = {
			LastAction = {},
			Pound = nil,
			LastPoundId = 0,
			Violations = 0,
			ViolationUpdatedAt = os.clock(),
		}
		states[player] = state
	end
	return state
end

local function addViolation(player: Player, reason: string, fields: { [string]: any }?)
	local state = getState(player)
	local now = os.clock()
	local decay = math.floor((now - state.ViolationUpdatedAt) / GameConfig.Security.ViolationDecaySeconds)
	if decay > 0 then
		state.Violations = math.max(0, state.Violations - decay)
		state.ViolationUpdatedAt += decay * GameConfig.Security.ViolationDecaySeconds
	end
	state.Violations += 1

	local logFields: { [string]: any } = fields or {}
	logFields.UserId = player.UserId
	logFields.Reason = reason
	logFields.Score = state.Violations
	if state.Violations % GameConfig.Security.ViolationWarnThreshold == 0 then
		logger:Warn("MovementViolations", logFields)
	else
		logger:Debug("MovementViolation", logFields)
	end

	local kickAt = GameConfig.Security.ViolationKickThreshold
	if kickAt > 0 and state.Violations >= kickAt then
		logger:Warn("KickedForViolations", { UserId = player.UserId, Score = state.Violations })
		player:Kick("Disconnected: unexpected movement data.")
	end
end

local function feetOffsetFor(record: CharacterService.CharacterRecord): number
	local humanoid = record.Humanoid
	local isR15 = humanoid.RigType == Enum.HumanoidRigType.R15
	local leg = record.Character:FindFirstChild("Left Leg")
	local legHeight = if leg and leg:IsA("BasePart") then leg.Size.Y else 2
	return MovementMath.FeetOffset(isR15, humanoid.HipHeight, record.RootPart.Size.Y, legHeight)
end

local function groundBelow(origin: Vector3, distance: number, character: Model): RaycastResult?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.RespectCanCollide = true
	return Workspace:Raycast(origin, Vector3.new(0, -distance, 0), params)
end

local function clampedPing(player: Player): number
	local ok, ping = pcall(player.GetNetworkPing, player)
	if not ok or type(ping) ~= "number" or ping ~= ping then
		return Validation.MaxPingAllowance
	end
	return math.clamp(ping, 0, Validation.MaxPingAllowance)
end

local function maxPoundLifetime(): number
	return GroundPound.WindupTime + GroundPound.MaxDescentTime + Validation.LatencyGrace + Validation.MaxPingAllowance
end

local function handlePoundStart(
	player: Player,
	record: CharacterService.CharacterRecord,
	state: PlayerState,
	poundId: any,
	now: number
)
	if
		type(poundId) ~= "number"
		or poundId ~= math.floor(poundId)
		or poundId <= state.LastPoundId
		or poundId > state.LastPoundId + MAX_POUND_ID_STEP
	then
		addViolation(player, "BadPoundId", { PoundId = tostring(poundId) })
		return
	end
	local active = state.Pound
	if active and not active.Processed and now - active.StartedAt <= maxPoundLifetime() then
		addViolation(player, "PoundAlreadyActive")
		return
	end

	local feetOffset = feetOffsetFor(record)
	local requiredClearance = math.max(0, GroundPound.MinActivationHeight - Validation.ActivationHeightTolerance)
	if groundBelow(record.RootPart.Position, feetOffset + requiredClearance, record.Character) then
		-- The server's view lags the client's; treat as a soft rejection.
		logger:Debug("PoundStartTooLow", { UserId = player.UserId })
		return
	end

	state.LastPoundId = poundId
	state.Pound = {
		Id = poundId,
		StartedAt = now,
		StartRootPosition = record.RootPart.Position,
		FeetOffset = feetOffset,
		Processed = false,
	}
end

local function onMovementAction(player: Player, ...: any)
	if not limiter:Allow(player) then
		logger:Debug("MovementRateLimited", { UserId = player.UserId })
		return
	end
	local count = select("#", ...)
	local action, poundId = ...
	if count < 1 or count > 2 or type(action) ~= "string" or MIN_INTERVAL[action] == nil then
		addViolation(player, "BadPayload", { Count = count })
		return
	end
	if not ACTION_ENABLED[action] then
		addViolation(player, "DisabledAction", { Action = action })
		return
	end
	local record = CharacterService.GetAliveRecord(player)
	if not record then
		return -- late packet after death/respawn
	end

	local state = getState(player)
	local now = os.clock()
	local last = state.LastAction[action]
	if last and now - last < MIN_INTERVAL[action] then
		addViolation(player, "CooldownBypass", {
			Action = action,
			Interval = string.format("%.3f", now - last),
		})
		return
	end
	state.LastAction[action] = now

	if (action :: MovementAction) == "GroundPoundStart" then
		handlePoundStart(player, record, state, poundId, now)
	end
end

local function broadcastImpact(source: Player, effect: Types.ImpactEffect)
	local remoteTable = remotes :: Types.Remotes
	local radius = Validation.ImpactEffectReplicationRadius
	for _, other in Players:GetPlayers() do
		if other == source then
			remoteTable.ImpactEffect:FireClient(other, effect)
		else
			local otherRecord = CharacterService.GetRecord(other)
			if otherRecord and (otherRecord.RootPart.Position - effect.Position).Magnitude <= radius then
				remoteTable.ImpactEffect:FireClient(other, effect)
			end
		end
	end
end

local function onGroundPoundImpact(player: Player, ...: any)
	if not limiter:Allow(player) then
		logger:Debug("ImpactRateLimited", { UserId = player.UserId })
		return
	end
	if select("#", ...) ~= 2 then
		addViolation(player, "BadPayload")
		return
	end
	local poundId, position = ...
	if type(poundId) ~= "number" or typeof(position) ~= "Vector3" or not MovementMath.IsFiniteVector(position) then
		addViolation(player, "BadPayload")
		return
	end

	local state = getState(player)
	local pound = state.Pound
	if not pound or pound.Id ~= poundId then
		-- Start may have been soft-rejected (lag) or never sent; nothing to do.
		logger:Debug("ImpactWithoutPound", { UserId = player.UserId, PoundId = poundId })
		return
	end
	if pound.Processed then
		logger:Debug("DuplicateImpact", { UserId = player.UserId, PoundId = poundId })
		return
	end
	pound.Processed = true -- one impact per pound, even if a check below rejects it

	local record = CharacterService.GetAliveRecord(player)
	if not record then
		return
	end

	local now = os.clock()
	local ping = clampedPing(player)
	if now - pound.StartedAt > maxPoundLifetime() then
		logger:Debug("ImpactTooLate", { UserId = player.UserId })
		return
	end

	local positionTolerance = Validation.ImpactPositionTolerance + GroundPound.MaxDescentSpeed * ping
	local distance = (position - record.RootPart.Position).Magnitude
	if distance > positionTolerance then
		addViolation(player, "ImpactFarFromCharacter", { Distance = math.floor(distance) })
		return
	end

	local drift = position - pound.StartRootPosition
	local horizontalDrift = Vector3.new(drift.X, 0, drift.Z).Magnitude
	local driftTolerance = Validation.ImpactHorizontalTolerance + Validation.ImpactHorizontalSpeedAllowance * ping
	if horizontalDrift > driftTolerance then
		addViolation(player, "ImpactDrift", { Drift = math.floor(horizontalDrift) })
		return
	end
	if position.Y > pound.StartRootPosition.Y + Validation.ImpactVerticalTolerance then
		addViolation(player, "ImpactAboveStart")
		return
	end

	local probeLift = 3
	local ground = groundBelow(
		position + Vector3.new(0, probeLift, 0),
		probeLift + Validation.ImpactGroundProbeDistance,
		record.Character
	)
	if not ground then
		logger:Debug("ImpactNoGround", { UserId = player.UserId })
		return
	end

	local center = ground.Position
	local power = math.max(0, pound.StartRootPosition.Y - pound.FeetOffset - center.Y)
	local broken = DestructibleService.ProcessImpact(player, center, GroundPound.ImpactRadius, power)

	broadcastImpact(player, {
		Position = center,
		Radius = GroundPound.Shockwave.Radius,
		SourceUserId = player.UserId,
		Broken = broken,
	})
end

local function resetCharacterState(player: Player)
	local state = states[player]
	if state then
		state.Pound = nil
		state.LastPoundId = 0
		table.clear(state.LastAction)
	end
end

function MovementValidationService.Init(remoteTable: Types.Remotes)
	remotes = remoteTable
end

function MovementValidationService.Start()
	assert(not started, "MovementValidationService already started")
	assert(remotes, "MovementValidationService.Init must run before Start")
	started = true
	local remoteTable = remotes :: Types.Remotes

	remoteTable.MovementAction.OnServerEvent:Connect(onMovementAction)
	remoteTable.GroundPoundImpact.OnServerEvent:Connect(onGroundPoundImpact)

	CharacterService.OnSpawned(function(player)
		resetCharacterState(player)
	end)
	CharacterService.OnDied(function(player)
		local state = states[player]
		if state then
			state.Pound = nil
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
		limiter:Remove(player)
	end)
end

return MovementValidationService
