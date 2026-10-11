--!strict
-- The single gameplay-audio system (see AudioConfig for every sound).
--
-- Playback:
--   * Bounded pools: each sound key owns at most Sound.Voices Sound instances
--     per owner (a character, the UI, or the world host), created on first
--     use and reused round-robin. Nothing creates a Sound per play or per frame.
--   * Per-key cooldowns stop repeated events, marker/fallback overlaps and
--     rapid ability use from stacking copies; a compressor on the master
--     SoundGroup keeps simultaneous sounds from clipping.
--   * Ids are preloaded; an id that fails to load is reported once and that
--     sound stays silent. Empty ids are silent by design.
--
-- Roblox's RbxCharacterSounds (Running/Jumping/Landing/Died/... under every
-- HumanoidRootPart, on every client) is left in charge of anything not
-- configured here. It is changed only where this system replaces it:
--   * footsteps configured -> its "Running" loop is muted (Volume 0)
--   * otherwise            -> its "Running" loop is retuned by speed
--                             (PlaybackSpeed/Volume), which it never writes
--   * Sounds.Jump / Sounds.Death configured -> "Jumping" / "Died" muted
--
-- Characters: every player's character within HearingRadius is tracked, so
-- other players' footsteps, jumps and deaths sound the same as yours. They
-- are derived locally from replicated movement, so no audio is sent over
-- the network. Ability sounds are played by the acting player's client only.

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local AnimationConfig = require(Config:WaitForChild("AnimationConfig"))
local AudioConfig = require(Config:WaitForChild("AudioConfig"))
local LocomotionMath = require(Shared:WaitForChild("Math"):WaitForChild("LocomotionMath"))
local Logger = require(Shared:WaitForChild("Utilities"):WaitForChild("Logger"))
local ResourceCleanup = require(Shared:WaitForChild("Utilities"):WaitForChild("ResourceCleanup"))
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent.Parent
local CharacterLifecycle = require(Client.Utilities.CharacterLifecycle)
local Effects = require(Client.Utilities.Effects)
local AnimationController = require(script.Parent.AnimationController)

type SoundEntry = AudioConfig.Sound

type Voice = {
	Sound: Sound,
	Token: number,
}

type Pool = {
	Voices: { Voice },
	Next: number,
}

type FootstepState = {
	Voices: { Sound },
	Next: number,
	Distance: number,
	LastVariant: number?,
	MarkerUntil: number,
}

type Tracked = {
	Player: Player,
	IsLocal: boolean,
	Character: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Pools: { [string]: Pool },
	LastPlayed: { [string]: number },
	Footsteps: FootstepState,
	DefaultRunning: Instance?,
	AppliedLoopSpeed: number,
	AppliedLoopVolume: number,
	Cleanup: ResourceCleanup.ResourceCleanup,
}

export type Dependencies = {
	GetMovementState: () -> Types.MovementState,
}

local Sounds = AudioConfig.Sounds
local Footsteps = AudioConfig.Footsteps
local Locomotion = AnimationConfig.Locomotion
local CUT_FADE = 0.06
local PART_TIMEOUT = 10
local FOOTSTEP_STATES: { [Enum.HumanoidStateType]: boolean } = {
	[Enum.HumanoidStateType.Running] = true,
	[Enum.HumanoidStateType.RunningNoPhysics] = true,
}

local logger = Logger.new("AudioController")

local AudioController = {}

local groups: { [string]: SoundGroup } = {}
local uiFolder: Folder? = nil
local uiPools: { [string]: Pool } = {}
local uiLastPlayed: { [string]: number } = {}
local worldHost: Part? = nil
local worldPools: { [string]: Pool } = {}
local worldLastPlayed: { [string]: number } = {}
local tracked: { [Model]: Tracked } = {}
local localTracked: Tracked? = nil
local playerCleanups: { [Player]: ResourceCleanup.ResourceCleanup } = {}
local unavailable: { [string]: boolean } = {}
local customFootsteps = false
local shardStreak = 0
local lastShardAt = -math.huge
local hasSpawnedBefore = false
local getMovementState: (() -> Types.MovementState)? = nil
local random = Random.new()
local started = false

------------------------------------------------------------------------------
-- Pools and playback
------------------------------------------------------------------------------

local function isPlayable(entry: SoundEntry): boolean
	return entry.SoundId ~= "" and not unavailable[entry.SoundId]
end

local function newSound(entry: SoundEntry, parent: Instance): Sound
	local sound = Instance.new("Sound")
	sound.SoundId = entry.SoundId
	sound.Volume = entry.Volume
	sound.Looped = entry.Looped
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = entry.RollOffMinDistance
	sound.RollOffMaxDistance = entry.RollOffMaxDistance
	sound.SoundGroup = groups[entry.Group]
	sound.Parent = parent
	return sound
end

local function getPool(pools: { [string]: Pool }, key: string, entry: SoundEntry, makeParent: () -> Instance): Pool
	local pool = pools[key]
	if pool then
		return pool
	end
	local voices: { Voice } = {}
	for _ = 1, math.max(1, entry.Voices) do
		table.insert(voices, { Sound = newSound(entry, makeParent()), Token = 0 })
	end
	local created: Pool = { Voices = voices, Next = 0 }
	pools[key] = created
	return created
end

local function cooledDown(lastPlayed: { [string]: number }, key: string, entry: SoundEntry): boolean
	local now = os.clock()
	local last = lastPlayed[key]
	if last and now - last < entry.Cooldown then
		return false
	end
	lastPlayed[key] = now
	return true
end

local function fadeOutAndStop(voice: Voice, token: number)
	local sound = voice.Sound
	local tween = TweenService:Create(sound, TweenInfo.new(CUT_FADE, Enum.EasingStyle.Linear), { Volume = 0 })
	tween.Completed:Once(function()
		if voice.Token == token then
			sound:Stop()
		end
	end)
	tween:Play()
end

-- Plays the next voice of a pool; returns the voice and its play token.
local function playVoice(pool: Pool, entry: SoundEntry, speedMultiplier: number): (Voice, number)
	pool.Next = pool.Next % #pool.Voices + 1
	local voice = pool.Voices[pool.Next]
	voice.Token += 1
	local token = voice.Token
	local sound = voice.Sound
	local variance = entry.PitchVariance
	sound.Volume = entry.Volume
	sound.PlaybackSpeed = entry.PlaybackSpeed * speedMultiplier * (1 + random:NextNumber(-variance, variance))
	sound.TimePosition = entry.StartTime
	sound:Play()
	if entry.MaxDuration > 0 and not entry.Looped then
		task.delay(entry.MaxDuration, function()
			if voice.Token == token and sound.Parent ~= nil then
				fadeOutAndStop(voice, token)
			end
		end)
	end
	return voice, token
end

local function playOnCharacter(record: Tracked, key: string, entry: SoundEntry, speedMultiplier: number): (Voice?, number)
	if not cooledDown(record.LastPlayed, key, entry) then
		return nil, 0
	end
	local pool = getPool(record.Pools, key, entry, function()
		return record.Root
	end)
	return playVoice(pool, entry, speedMultiplier)
end

local function getWorldHost(): Part
	local host = worldHost
	if host and host.Parent ~= nil then
		return host
	end
	local part = Instance.new("Part")
	part.Name = "AudioHost"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.Parent = Effects.GetFolder()
	worldHost = part
	table.clear(worldPools) -- old attachments went with the old host
	return part
end

local function getUiFolder(): Folder
	local folder = uiFolder
	if folder and folder.Parent ~= nil then
		return folder
	end
	local newFolder = Instance.new("Folder")
	newFolder.Name = "PlatformerUISounds"
	newFolder.Parent = SoundService
	uiFolder = newFolder
	table.clear(uiPools)
	return newFolder
end

local function getEntry(key: string): SoundEntry?
	local entry = Sounds[key]
	if not entry then
		logger:Warn("UnknownSound", { Key = key })
		return nil
	end
	return if isPlayable(entry) then entry else nil
end

-- Plays a sound by AudioConfig key. Character-scoped sounds play on
-- `character` (default: the local player's); UI sounds are 2D and local.
function AudioController.Play(key: string, character: Model?, speedMultiplier: number?)
	local entry = getEntry(key)
	if not entry then
		return
	end
	local multiplier = speedMultiplier or 1
	if entry.Scope == "UI" then
		if cooledDown(uiLastPlayed, key, entry) then
			local folder = getUiFolder()
			playVoice(getPool(uiPools, key, entry, function()
				return folder
			end), entry, multiplier)
		end
		return
	end
	local record = if character then tracked[character] else localTracked
	if not record then
		return
	end
	if entry.Scope == "World" then
		AudioController.PlayAt(key, record.Root.Position)
		return
	end
	playOnCharacter(record, key, entry, multiplier)
end

-- Plays a sound at a world position (World scope).
function AudioController.PlayAt(key: string, position: Vector3)
	local entry = getEntry(key)
	if not entry or not cooledDown(worldLastPlayed, key, entry) then
		return
	end
	local host = getWorldHost()
	local pool = getPool(worldPools, key, entry, function()
		local attachment = Instance.new("Attachment")
		attachment.Parent = host
		return attachment
	end)
	local nextVoice = pool.Voices[pool.Next % #pool.Voices + 1]
	local attachment = nextVoice.Sound.Parent
	if attachment and attachment:IsA("Attachment") then
		attachment.WorldPosition = position
	end
	playVoice(pool, entry, 1)
end

-- Starts a looped character sound on the local player; returns a stop
-- function (nil if the sound is silent). Stopping twice is harmless.
function AudioController.StartLoop(key: string): (() -> ())?
	local entry = getEntry(key)
	local record = localTracked
	if not entry or not record then
		return nil
	end
	local voice, token = playOnCharacter(record, key, entry, 1)
	if not voice then
		return nil
	end
	local playingVoice = voice
	return function()
		if playingVoice.Token == token then
			fadeOutAndStop(playingVoice, token)
		end
	end
end

-- Pickup sound after the server confirmed it. Shards rise in pitch during
-- a quick streak (AudioConfig.CollectChain); Power Orbs use their own sound.
function AudioController.PlayCollect(currencyType: Types.CurrencyType)
	if currencyType == "PowerOrbs" then
		AudioController.Play("PowerOrbCollect")
		return
	end
	local chain = AudioConfig.CollectChain
	local now = os.clock()
	shardStreak = if now - lastShardAt <= chain.Window then shardStreak + 1 else 0
	lastShardAt = now
	AudioController.Play("ShardCollect", nil, LocomotionMath.ChainSpeed(shardStreak, chain.SemitonesPerStep, chain.MaxSteps))
end

------------------------------------------------------------------------------
-- Footsteps
------------------------------------------------------------------------------

local function runWeightFor(speed: number): number
	local _, runWeight = LocomotionMath.WalkRunWeights(speed, Locomotion.RunBlendStart, Locomotion.RunBlendEnd)
	return runWeight
end

local function horizontalSpeed(root: BasePart): number
	local velocity = root.AssemblyLinearVelocity
	return Vector3.new(velocity.X, 0, velocity.Z).Magnitude
end

local function footstepEligible(record: Tracked): boolean
	local humanoid = record.Humanoid
	if humanoid.Health <= 0 or not FOOTSTEP_STATES[humanoid:GetState()] then
		return false
	end
	if record.IsLocal then
		local state = if getMovementState then (getMovementState :: () -> Types.MovementState)() else "Dead"
		return Footsteps.ActiveStates[state] == true
	end
	return true
end

local function floorMaterial(record: Tracked): Enum.Material
	if record.IsLocal then
		return record.Humanoid.FloorMaterial
	end
	-- Other players: one short ray per step (not per frame) finds the surface.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { record.Character }
	params.RespectCanCollide = true
	local result = Workspace:Raycast(record.Root.Position, Vector3.new(0, -8, 0), params)
	return if result then result.Material else record.Humanoid.FloorMaterial
end

local function playFootstep(record: Tracked, runWeight: number)
	local surface = LocomotionMath.SurfaceFor(floorMaterial(record).Name, Footsteps.MaterialSurfaces, Footsteps.Surfaces)
	local ids = Footsteps.Surfaces[surface]
	if not ids or #ids == 0 then
		return
	end
	local state = record.Footsteps
	local index = LocomotionMath.PickVariant(#ids, state.LastVariant, random:NextNumber())
	local id = ids[index]
	if unavailable[id] then
		return
	end
	state.LastVariant = index
	if #state.Voices == 0 then
		for _ = 1, math.max(1, Footsteps.Voices) do
			local sound = Instance.new("Sound")
			sound.Name = "PlatformerFootstep"
			sound.RollOffMode = Enum.RollOffMode.InverseTapered
			sound.RollOffMinDistance = Footsteps.RollOffMinDistance
			sound.RollOffMaxDistance = Footsteps.RollOffMaxDistance
			sound.SoundGroup = groups.Footsteps
			sound.Parent = record.Root
			table.insert(state.Voices, sound)
		end
	end
	state.Next = state.Next % #state.Voices + 1
	local sound = state.Voices[state.Next]
	sound.SoundId = id
	sound.Volume = LocomotionMath.Blend(Footsteps.WalkVolume, Footsteps.RunVolume, runWeight)
	local variance = Footsteps.PitchVariance
	sound.PlaybackSpeed = 1 + random:NextNumber(-variance, variance)
	sound.TimePosition = 0
	sound:Play()
end

local function setDefaultLoop(record: Tracked, playbackSpeed: number, volume: number)
	local running = record.DefaultRunning
	if not running or running.Parent == nil then
		return
	end
	if math.abs(record.AppliedLoopSpeed - playbackSpeed) > 0.02 then
		record.AppliedLoopSpeed = playbackSpeed;
		(running :: any).PlaybackSpeed = playbackSpeed
	end
	if math.abs(record.AppliedLoopVolume - volume) > 0.02 then
		record.AppliedLoopVolume = volume;
		(running :: any).Volume = volume
	end
end

-- One Heartbeat pass over tracked characters. Work per character is a few
-- arithmetic operations; sounds only play when a step is due.
local function updateFootsteps(deltaTime: number)
	if not Footsteps.Enabled then
		return
	end
	local camera = Workspace.CurrentCamera
	local listener = if camera then camera.CFrame.Position else nil
	local now = os.clock()
	-- Keys + index (not `for _, record in`): works around a Luau solver quirk
	-- with generic methods inside iterated record types.
	for character in tracked do
		local record = tracked[character]
		if record.Root.Parent == nil then
			continue
		end
		local inRange = record.IsLocal
			or (listener ~= nil and (record.Root.Position - listener).Magnitude <= Footsteps.HearingRadius)
		local speed = horizontalSpeed(record.Root)
		local eligible = inRange and footstepEligible(record) and speed >= Locomotion.MoveStopSpeed
		local runWeight = runWeightFor(speed)

		if not customFootsteps then
			local loop = Footsteps.DefaultLoop
			setDefaultLoop(
				record,
				LocomotionMath.Blend(loop.WalkPlaybackSpeed, loop.RunPlaybackSpeed, runWeight),
				if eligible or not record.IsLocal
					then LocomotionMath.Blend(loop.WalkVolume, loop.RunVolume, runWeight)
					else 0
			)
			continue
		end

		local state = record.Footsteps
		if not eligible then
			-- Half a stride banked, so the first step comes soon after moving again.
			state.Distance = Footsteps.WalkStride * 0.5
			continue
		end
		if record.IsLocal and now < state.MarkerUntil then
			continue -- the animation's Footstep events are driving steps
		end
		state.Distance += speed * deltaTime
		local stride = LocomotionMath.Blend(Footsteps.WalkStride, Footsteps.RunStride, runWeight)
		if state.Distance >= stride then
			state.Distance = 0
			playFootstep(record, runWeight)
		end
	end
end

local function onFootstepMarker(context: CharacterLifecycle.Context)
	local record = localTracked
	if not record or record.Character ~= context.Character or not customFootsteps or not footstepEligible(record) then
		return
	end
	record.Footsteps.MarkerUntil = os.clock() + Footsteps.MarkerSuppressTime
	record.Footsteps.Distance = 0
	playFootstep(record, runWeightFor(horizontalSpeed(record.Root)))
end

------------------------------------------------------------------------------
-- Character tracking (every player, for footsteps, jumps and deaths)
------------------------------------------------------------------------------

local function adoptDefaultSound(record: Tracked, child: Instance)
	if not (child:IsA("Sound") or child:IsA("AudioPlayer")) then
		return
	end
	local name = child.Name
	if name == "Running" then
		record.DefaultRunning = child
		record.AppliedLoopSpeed = -1
		record.AppliedLoopVolume = -1
		if customFootsteps then
			(child :: any).Volume = 0
		end
	elseif (name == "Jumping" and isPlayable(Sounds.Jump)) or (name == "Died" and isPlayable(Sounds.Death)) then
		(child :: any).Volume = 0
	end
end

local function untrack(character: Model)
	local record = tracked[character]
	if not record then
		return
	end
	tracked[character] = nil
	if localTracked == record then
		localTracked = nil
	end
	record.Cleanup:Destroy()
end

local function track(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", PART_TIMEOUT)
	local root = character:WaitForChild("HumanoidRootPart", PART_TIMEOUT)
	if player.Character ~= character or character.Parent == nil or tracked[character] then
		return
	end
	if not (humanoid and humanoid:IsA("Humanoid")) or not (root and root:IsA("BasePart")) then
		return
	end
	local cleanup = ResourceCleanup.new(`Audio:{player.UserId}`)
	local record: Tracked = {
		Player = player,
		IsLocal = player == Players.LocalPlayer,
		Character = character,
		Humanoid = humanoid,
		Root = root,
		Pools = {},
		LastPlayed = {},
		Footsteps = { Voices = {}, Next = 0, Distance = 0, LastVariant = nil, MarkerUntil = 0 },
		DefaultRunning = nil,
		AppliedLoopSpeed = -1,
		AppliedLoopVolume = -1,
		Cleanup = cleanup,
	}
	-- Pooled Sounds live under the root and go with the character; the
	-- cleanup also destroys them if only tracking stops.
	cleanup:Add(function()
		for _, pool in record.Pools do
			for _, voice in pool.Voices do
				voice.Sound:Destroy()
			end
		end
		for _, sound in record.Footsteps.Voices do
			sound:Destroy()
		end
	end)

	for _, child in root:GetChildren() do
		adoptDefaultSound(record, child)
	end
	cleanup:Connect(root.ChildAdded, function(child: Instance)
		adoptDefaultSound(record, child)
	end)
	cleanup:Connect(humanoid.StateChanged, function(_, new: Enum.HumanoidStateType)
		if new == Enum.HumanoidStateType.Jumping then
			AudioController.Play("Jump", character)
		end
	end)
	cleanup:Connect(humanoid.Died, function()
		AudioController.Play("Death", character)
	end)

	tracked[character] = record
	if record.IsLocal then
		localTracked = record
	end
end

local function onPlayerAdded(player: Player)
	if playerCleanups[player] then
		return
	end
	local cleanup = ResourceCleanup.new(`AudioPlayer:{player.UserId}`)
	playerCleanups[player] = cleanup
	cleanup:Connect(player.CharacterAdded, function(character: Model)
		track(player, character)
	end)
	cleanup:Connect(player.CharacterRemoving, untrack)
	if player.Character then
		task.spawn(track, player, player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	if player.Character then
		untrack(player.Character)
	end
	local cleanup = playerCleanups[player]
	playerCleanups[player] = nil
	if cleanup then
		cleanup:Destroy()
	end
end

------------------------------------------------------------------------------
-- Startup
------------------------------------------------------------------------------

local function buildMixer()
	local mix = AudioConfig.Mix
	local master = Instance.new("SoundGroup")
	master.Name = "PlatformerAudio"
	master.Volume = mix.MasterVolume
	local compressor = Instance.new("CompressorSoundEffect")
	compressor.Threshold = mix.CompressorThreshold
	compressor.Ratio = mix.CompressorRatio
	compressor.Attack = mix.CompressorAttack
	compressor.Release = mix.CompressorRelease
	compressor.Parent = master
	local specs: { { Name: string, Volume: number } } = {
		{ Name = "Footsteps", Volume = mix.FootstepsVolume },
		{ Name = "Actions", Volume = mix.ActionsVolume },
		{ Name = "Interface", Volume = mix.InterfaceVolume },
	}
	for _, spec in specs do
		local group = Instance.new("SoundGroup")
		group.Name = spec.Name
		group.Volume = spec.Volume
		group.Parent = master
		groups[spec.Name] = group
	end
	master.Parent = SoundService
end

local function preloadSounds()
	local ids: { string } = {}
	local seen: { [string]: boolean } = {}
	local function add(id: string)
		if id ~= "" and not seen[id] then
			seen[id] = true
			table.insert(ids, id)
		end
	end
	for _, entry in Sounds do
		add(entry.SoundId)
	end
	for _, list in Footsteps.Surfaces do
		for _, id in list do
			add(id)
		end
	end
	if #ids == 0 then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(ids, function(assetId: string, status: Enum.AssetFetchStatus)
				if status ~= Enum.AssetFetchStatus.Success and not unavailable[assetId] then
					unavailable[assetId] = true
					logger:Warn("SoundUnavailable", { Id = assetId, Status = status.Name, Effect = "silent" })
				end
			end)
		end)
		if not ok then
			logger:Warn("PreloadFailed", { Error = err })
		end
	end)
end

function AudioController.Init(dependencies: Dependencies)
	getMovementState = dependencies.GetMovementState
end

function AudioController.Start()
	assert(not started, "AudioController already started")
	started = true

	for _, list in Footsteps.Surfaces do
		if #list > 0 then
			customFootsteps = true
		end
	end
	buildMixer()
	preloadSounds()

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	RunService.Heartbeat:Connect(updateFootsteps)
	AnimationController.OnMarker("Footstep", onFootstepMarker)

	CharacterLifecycle.Register("AudioController", {
		OnSpawn = function()
			if hasSpawnedBefore then
				AudioController.Play("Respawn")
			end
			hasSpawnedBefore = true
		end,
	})
end

return AudioController
