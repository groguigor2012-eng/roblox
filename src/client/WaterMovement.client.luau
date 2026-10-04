--!strict
-- Water feel: soft splashing footsteps while wading through shallow water,
-- slow strokes while swimming in the deep pools, a splash when you drop in,
-- and slower movement while swimming.
--
-- Wading is detected by reading the terrain voxel at the character's feet, so it
-- works anywhere there is terrain water, not just in specific rooms.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Config = require(ReplicatedStorage:WaitForChild("Poolrooms"):WaitForChild("Config"))

local player = Players.LocalPlayer
local terrain = workspace.Terrain
local rng = Random.new()

local STRIDE = 3.4 -- studs travelled per wading footstep
local STROKE_INTERVAL = 1.1 -- seconds between swim strokes while moving
local DROP_SPEED = 10 -- downward speed that counts as "jumping in"

SoundService.AmbientReverb = Enum.ReverbType.Bathroom

if Config.AMBIENT_SOUND_ID ~= "" then
	local ambience = Instance.new("Sound")
	ambience.Name = "PoolAmbience"
	ambience.SoundId = Config.AMBIENT_SOUND_ID
	ambience.Looped = true
	ambience.Volume = 0.35
	ambience.Parent = SoundService
	ambience:Play()
end

local function isWater(position: Vector3): boolean
	local cell = Vector3.new(math.floor(position.X / 4), math.floor(position.Y / 4), math.floor(position.Z / 4)) * 4
	local materials = terrain:ReadVoxels(Region3.new(cell, cell + Vector3.new(4, 4, 4)), 4)
	return materials[1][1][1] == Enum.Material.Water
end

-- Small round-robin pool so overlapping splashes don't cut each other off.
local function makePool(parent: Instance, soundId: string, count: number): { Sound }
	local pool = {}
	for index = 1, count do
		local sound = Instance.new("Sound")
		sound.Name = `PoolSplash{index}`
		sound.SoundId = soundId
		sound.RollOffMaxDistance = 60
		sound.Parent = parent
		table.insert(pool, sound)
	end
	return pool
end

local function setupCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	local steps = makePool(rootPart, Config.SPLASH_STEP_SOUND, 3)
	local strokes = makePool(rootPart, Config.SWIM_STROKE_SOUND, 2)
	local nextSound = 1
	local function play(pool: { Sound }, volume: number, pitchMin: number, pitchMax: number)
		local sound = pool[(nextSound - 1) % #pool + 1]
		nextSound += 1
		sound.Volume = volume
		sound.PlaybackSpeed = rng:NextNumber(pitchMin, pitchMax)
		sound.TimePosition = 0
		sound:Play()
	end

	-- Roblox's default tile footstep ("Running") is muted while wading. The default
	-- character sound script may create it after us, so it is looked up lazily.
	local running: Sound? = nil
	local runningVolume = 0

	local baseWalkSpeed = humanoid.WalkSpeed
	local wasWading = false
	local distance = 0
	local strokeTimer = 0

	local connection = RunService.Heartbeat:Connect(function(dt: number)
		if humanoid.Health <= 0 then
			return
		end
		local velocity = rootPart.AssemblyLinearVelocity
		local horizontal = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		local swimming = humanoid:GetState() == Enum.HumanoidStateType.Swimming

		local feet = rootPart.Position - Vector3.new(0, humanoid.HipHeight + rootPart.Size.Y / 2 - 0.5, 0)
		local wading = not swimming and isWater(feet)

		-- Splash when landing in water from a jump or fall.
		if (wading or swimming) and not wasWading and velocity.Y < -DROP_SPEED then
			play(steps, 0.55, 0.75, 0.9)
		end

		if wading and humanoid.FloorMaterial ~= Enum.Material.Air then
			distance += horizontal * dt
			if distance >= STRIDE then
				distance = 0
				play(steps, 0.22, 0.95, 1.2)
			end
		else
			distance = STRIDE * 0.6 -- first step after entering water comes quickly
		end

		if swimming and horizontal > 1 then
			strokeTimer += dt
			if strokeTimer >= STROKE_INTERVAL then
				strokeTimer = 0
				play(strokes, 0.18, 0.85, 1.05)
			end
		else
			strokeTimer = STROKE_INTERVAL * 0.5
		end

		-- Slower, heavier swimming.
		local targetSpeed = if swimming then baseWalkSpeed * Config.SWIM_SPEED_MULTIPLIER else baseWalkSpeed
		if humanoid.WalkSpeed ~= targetSpeed then
			humanoid.WalkSpeed = targetSpeed
		end

		if not running then
			local found = rootPart:FindFirstChild("Running")
			if found and found:IsA("Sound") then
				running = found
				runningVolume = found.Volume
			end
		end
		if running then
			running.Volume = if wading then 0 else runningVolume
		end

		wasWading = wading or swimming
	end)

	humanoid.Died:Once(function()
		connection:Disconnect()
	end)
	character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			connection:Disconnect()
		end
	end)
end

if player.Character then
	task.spawn(setupCharacter, player.Character)
end
player.CharacterAdded:Connect(setupCharacter)
