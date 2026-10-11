--!strict
-- The local character's single animation authority (replaces the former
-- Utilities/CharacterAnimations loader). It:
--   * loads AnimationConfig entries onto the character's own Animator once
--     per character, caches them, and cleans them up with the character
--   * runs the walk/run (and optional idle) layer at Movement/Idle priority,
--     driven by real ground speed with configurable thresholds, blending
--     and speed-matched playback
--   * forwards animation events (markers) to listeners such as AudioController
--
-- Roblox's Animate script keeps running at Core priority underneath and
-- still plays jump, fall, climb, swim, sit, emotes and tool animations. The
-- walk/run layer reuses Animate's own walk/run assets unless AnimationConfig
-- names custom ones, so it never introduces an asset that is not already
-- part of the character. Ability animations play at Action priority, above
-- the layer, and the layer also fades out whenever the movement state is
-- not in AnimationConfig.Locomotion.ActiveStates.
--
-- Tracks played on the local Animator replicate to other players
-- automatically; nothing here sends data.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AnimationConfig = require(Shared:WaitForChild("Config"):WaitForChild("AnimationConfig"))
local LocomotionMath = require(Shared:WaitForChild("Math"):WaitForChild("LocomotionMath"))
local Logger = require(Shared:WaitForChild("Utilities"):WaitForChild("Logger"))
local Types = require(Shared:WaitForChild("Types"))

local CharacterLifecycle = require(script.Parent.Parent.Utilities.CharacterLifecycle)

type Entry = AnimationConfig.Entry
type Context = CharacterLifecycle.Context
type MarkerHandler = (context: Context) -> ()

export type Dependencies = {
	GetMovementState: () -> Types.MovementState,
}

type LayerTrack = {
	Track: AnimationTrack,
	Weight: number,
	Speed: number,
}

type Layer = {
	Walk: LayerTrack?,
	Run: LayerTrack?,
	Idle: LayerTrack?,
	Moving: boolean,
	SizeScale: number,
}

local Locomotion = AnimationConfig.Locomotion
local ANIMATE_WAIT = 5
-- Weight/speed changes smaller than this are not re-applied.
local APPLY_EPSILON = 0.03

local logger = Logger.new("AnimationController")

local AnimationController = {}

local tracksByContext: { [Context]: { [string]: AnimationTrack } } = {}
local unavailable: { [string]: boolean } = {}
local preloaded: { [string]: boolean } = {}
local markerHandlers: { [string]: { MarkerHandler } } = {}
local getMovementState: (() -> Types.MovementState)? = nil
local started = false

------------------------------------------------------------------------------
-- Track loading (shared by abilities, attack and locomotion)
------------------------------------------------------------------------------

local function markUnavailable(id: string, reason: string)
	if not unavailable[id] then
		unavailable[id] = true
		logger:Warn("AnimationUnavailable", { Id = id, Reason = reason, Effect = "using fallback" })
	end
end

local function dispatchMarker(name: string, context: Context)
	local handlers = markerHandlers[name]
	if not handlers then
		return
	end
	for _, handler in handlers do
		task.spawn(handler, context)
	end
end

-- Loads (once per character and cache key) and configures a track.
local function loadTrack(
	context: Context,
	cacheKey: string,
	id: string,
	priority: Enum.AnimationPriority,
	looped: boolean,
	markers: { string }
): AnimationTrack?
	if id == "" or unavailable[id] or not context.Alive then
		return nil
	end
	local cache = tracksByContext[context]
	if not cache then
		cache = {}
		tracksByContext[context] = cache
		context.Cleanup:Add(function()
			tracksByContext[context] = nil
		end)
	end
	local cached = cache[cacheKey]
	if cached then
		return cached
	end

	local animator = context.Humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end
	local animation = context.Cleanup:Add(Instance.new("Animation"))
	animation.AnimationId = id
	local ok, result = pcall(animator.LoadAnimation, animator, animation)
	if not ok then
		markUnavailable(id, tostring(result))
		return nil
	end
	local track = result :: AnimationTrack
	track.Priority = priority
	track.Looped = looped
	for _, marker in markers do
		context.Cleanup:Connect(track:GetMarkerReachedSignal(marker), function()
			dispatchMarker(marker, context)
		end)
	end
	context.Cleanup:Add(function()
		track:Stop(0)
		track:Destroy()
	end)
	cache[cacheKey] = track
	return track
end

-- True when the entry has an id that has not failed to load.
function AnimationController.IsAvailable(entry: Entry): boolean
	return entry.AnimationId ~= "" and not unavailable[entry.AnimationId]
end

-- Starts downloading configured animations in the background; failures are
-- reported once and those ids fall back for the session.
function AnimationController.Preload(ids: { string })
	local animations: { Instance } = {}
	for _, id in ids do
		if id ~= "" and not preloaded[id] then
			preloaded[id] = true
			local animation = Instance.new("Animation")
			animation.AnimationId = id
			table.insert(animations, animation)
		end
	end
	if #animations == 0 then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(animations, function(assetId: string, status: Enum.AssetFetchStatus)
				if status ~= Enum.AssetFetchStatus.Success then
					markUnavailable(assetId, `preload status {status.Name}`)
				end
			end)
		end)
		if not ok then
			logger:Warn("PreloadFailed", { Error = err })
		end
		for _, animation in animations do
			animation:Destroy()
		end
	end)
end

-- Plays an ability/attack entry. Returns the track, or nil when the entry is
-- not configured/available or the Animator is missing (callers fall back).
-- A track that is already playing is left alone, so it never overlaps itself.
function AnimationController.Play(context: Context, entry: Entry): AnimationTrack?
	if not AnimationController.IsAvailable(entry) then
		return nil
	end
	local track = loadTrack(context, entry.AnimationId, entry.AnimationId, entry.Priority, entry.Looped, entry.Markers)
	if not track then
		return nil
	end
	if not track.IsPlaying then
		track:Play(entry.FadeTime, 1, entry.Speed)
	end
	return track
end

-- Registers a listener for an animation event name (e.g. "Footstep").
function AnimationController.OnMarker(name: string, handler: MarkerHandler)
	local handlers = markerHandlers[name]
	if not handlers then
		handlers = {}
		markerHandlers[name] = handlers
	end
	table.insert(handlers, handler)
end

------------------------------------------------------------------------------
-- Locomotion layer
------------------------------------------------------------------------------

-- AnimationId of Animate.<valueName>.<animationName>, if present.
local function animateAssetId(character: Model, valueName: string, animationName: string): string?
	local animate = character:WaitForChild("Animate", ANIMATE_WAIT)
	local value = if animate then animate:FindFirstChild(valueName) else nil
	local animation = if value then value:FindFirstChild(animationName) else nil
	if animation and animation:IsA("Animation") and animation.AnimationId ~= "" then
		return animation.AnimationId
	end
	return nil
end

local function setLayerTrack(layerTrack: LayerTrack?, weight: number, speed: number)
	if not layerTrack then
		return
	end
	local track = layerTrack.Track
	if weight <= 0 then
		if track.IsPlaying then
			track:Stop(Locomotion.FadeTime)
		end
		layerTrack.Weight = 0
		return
	end
	if not track.IsPlaying then
		track:Play(Locomotion.FadeTime, weight, speed)
		layerTrack.Weight = weight
		layerTrack.Speed = speed
		return
	end
	if math.abs(layerTrack.Weight - weight) > APPLY_EPSILON then
		track:AdjustWeight(weight, Locomotion.FadeTime)
		layerTrack.Weight = weight
	end
	if math.abs(layerTrack.Speed - speed) > APPLY_EPSILON then
		track:AdjustSpeed(speed)
		layerTrack.Speed = speed
	end
end

local function updateLayer(context: Context, layer: Layer)
	local humanoid = context.Humanoid
	local state = if getMovementState then (getMovementState :: () -> Types.MovementState)() else "Dead"
	local eligible = context.Alive and Locomotion.ActiveStates[state] == true
	local velocity = context.RootPart.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	layer.Moving = eligible and LocomotionMath.IsMoving(speed, layer.Moving, Locomotion.MoveStartSpeed, Locomotion.MoveStopSpeed)

	if not layer.Moving then
		setLayerTrack(layer.Walk, 0, 1)
		setLayerTrack(layer.Run, 0, 1)
		setLayerTrack(layer.Idle, if eligible and humanoid.MoveDirection.Magnitude < 0.01 then 1 else 0, 1)
		return
	end
	setLayerTrack(layer.Idle, 0, 1)
	local walkWeight, runWeight = LocomotionMath.WalkRunWeights(speed, Locomotion.RunBlendStart, Locomotion.RunBlendEnd)
	local walkSpeed = LocomotionMath.PlaybackSpeed(
		speed,
		Locomotion.Walk.ReferenceSpeed,
		layer.SizeScale,
		Locomotion.MinPlaybackSpeed,
		Locomotion.MaxPlaybackSpeed
	)
	local runSpeed = LocomotionMath.PlaybackSpeed(
		speed,
		Locomotion.Run.ReferenceSpeed,
		layer.SizeScale,
		Locomotion.MinPlaybackSpeed,
		Locomotion.MaxPlaybackSpeed
	)
	if not layer.Run then
		walkWeight, runWeight = 1, 0
	end
	setLayerTrack(layer.Walk, walkWeight, walkSpeed)
	setLayerTrack(layer.Run, runWeight, runSpeed)
end

local function loadLayerTrack(context: Context, role: string, entry: AnimationConfig.LocomotionEntry, id: string?): LayerTrack?
	if not id then
		return nil
	end
	local track = loadTrack(context, `Locomotion:{role}`, id, entry.Priority, true, entry.Markers)
	return if track then { Track = track, Weight = 0, Speed = 1 } else nil
end

local function onSpawn(context: Context)
	if not Locomotion.Enabled then
		return
	end
	-- Waiting for the Animate script is bounded and off the spawn thread.
	context.Cleanup:Add(task.spawn(function()
		local character = context.Character
		local walkId = if Locomotion.Walk.AnimationId ~= ""
			then Locomotion.Walk.AnimationId
			else animateAssetId(character, "walk", "WalkAnim")
		local runId = if Locomotion.Run.AnimationId ~= ""
			then Locomotion.Run.AnimationId
			else animateAssetId(character, "run", "RunAnim")
		if not context.Alive or context.Cleanup:IsDestroyed() then
			return
		end
		local humanoid = context.Humanoid
		local layer: Layer = {
			Walk = loadLayerTrack(context, "Walk", Locomotion.Walk, walkId),
			Run = loadLayerTrack(context, "Run", Locomotion.Run, runId),
			Idle = loadLayerTrack(
				context,
				"Idle",
				Locomotion.Idle,
				if Locomotion.Idle.AnimationId ~= "" then Locomotion.Idle.AnimationId else nil
			),
			Moving = false,
			SizeScale = if humanoid.RigType == Enum.HumanoidRigType.R15
				then humanoid.HipHeight / Locomotion.DefaultHipHeight
				else 1,
		}
		if not layer.Walk and not layer.Run and not layer.Idle then
			logger:Warn("LocomotionLayerOff", {
				Reason = "no walk/run asset (no Animate script and none configured)",
				Effect = "Animate's defaults (if any) play alone",
			})
			return
		end
		if not layer.Walk then
			layer.Walk, layer.Run = layer.Run, nil
		end
		-- One update per frame for this character only: speed-matched
		-- playback needs the current speed every frame. Changes below
		-- APPLY_EPSILON are skipped, so steady movement makes no API calls.
		context.Cleanup:Connect(RunService.PreAnimation, function()
			updateLayer(context, layer)
		end)
	end))
end

local function onDied(context: Context)
	local cache = tracksByContext[context]
	if cache then
		for key, track in cache do
			if string.sub(key, 1, 11) == "Locomotion:" and track.IsPlaying then
				track:Stop(Locomotion.FadeTime)
			end
		end
	end
end

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------

function AnimationController.Init(dependencies: Dependencies)
	getMovementState = dependencies.GetMovementState
end

function AnimationController.Start()
	assert(not started, "AnimationController already started")
	started = true
	AnimationController.Preload({ Locomotion.Walk.AnimationId, Locomotion.Run.AnimationId, Locomotion.Idle.AnimationId })
	CharacterLifecycle.Register("AnimationController", {
		OnSpawn = onSpawn,
		OnDied = onDied,
	})
end

return AnimationController
