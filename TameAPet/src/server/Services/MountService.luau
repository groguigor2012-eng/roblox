-- Summoning, riding, flying and dismounting.
--
-- Network ownership strategy: SERVER. The mount's root is the assembly root (RootPriority)
-- and is pinned to the server with SetNetworkOwner(nil) after the rider is seated, and
-- re-asserted every step. Clients only send normalised movement intent (MountInput); the
-- server runs MountPhysics and drives LinearVelocity/AlignOrientation. Clients can't teleport,
-- exceed speed caps, fly on land mounts or steer anyone else's mount.
--
-- MountInput  (client -> server, UnreliableRemoteEvent, <= InputSendRate/s):
--   (forward: number [-1,1], turn: number [-1,1], vertical: number [-1,1], jump: boolean)
-- MountState  (server -> client):
--   { mounted = true, petId, species, displayName, speed, canFly, abilities } | { mounted = false, reason }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local MountConfig = require(ReplicatedStorage.Config.MountConfig)
local ZoneConfig = require(ReplicatedStorage.Config.ZoneConfig)
local MountPhysics = require(ReplicatedStorage.Shared.MountPhysics)
local RemoteNames = require(ReplicatedStorage.Shared.RemoteNames)

local MountStats = require(script.Parent.MountStats)
local Remotes = require(ServerScriptService.Security.Remotes)
local Validate = require(ServerScriptService.Security.Validate)
local MountFactory = require(ServerScriptService.World.MountFactory)
local RarityBillboard = require(ServerScriptService.World.RarityBillboard)
local ZoneRegistry = require(ServerScriptService.World.ZoneRegistry)
local AssetLibrary = require(ServerScriptService.World.AssetLibrary)

local Codes = RemoteNames.Codes

local MountService = {}
MountService.Name = "MountService"

type Mount = {
	player: Player,
	petId: string,
	speciesId: string,
	species: any,
	rig: MountFactory.MountRig,
	humanoid: Humanoid,
	state: MountPhysics.State,
	params: MountPhysics.Params,
	input: MountPhysics.Input,
	inputAt: number,
	seated: boolean,
	spawnedAt: number,
	flyingMode: boolean?,
	connections: { RBXScriptConnection },
}

local Services
local mounts: { [Player]: Mount } = {}
local lastSummon: { [Player]: number } = {}
local activeFolder: Folder

local function buildParams(species, upgradeLevel: number): MountPhysics.Params
	return {
		speed = MountStats.computeSpeed(species, upgradeLevel, MountConfig),
		turnRate = math.rad(MountConfig.TurnRateDegrees),
		airTurnRate = math.rad(MountConfig.AirTurnRateDegrees),
		acceleration = MountConfig.Acceleration,
		deceleration = MountConfig.Deceleration,
		reverseFactor = MountConfig.ReverseFactor,
		canFly = MountStats.canFly(species),
		canDoubleJump = MountStats.canDoubleJump(species),
		ascendSpeed = MountConfig.AscendSpeed,
		descendSpeed = MountConfig.DescendSpeed,
		verticalAcceleration = MountConfig.VerticalAcceleration,
		jumpVelocity = MountConfig.JumpVelocity,
		doubleJumpVelocity = MountConfig.DoubleJumpVelocity,
		maxAirJumps = MountConfig.MaxAirJumps,
		maxAltitude = MountConfig.MaxFlightAltitude,
		landingHeight = MountConfig.LandingHeight,
		bankAngle = math.rad(MountConfig.BankAngleDegrees),
		pitchAngle = math.rad(MountConfig.PitchAngleDegrees),
	}
end

local function sendState(mount: Mount)
	Remotes.fire("MountState", mount.player, {
		mounted = true,
		petId = mount.petId,
		species = mount.speciesId,
		displayName = mount.species.displayName,
		speed = math.floor(mount.params.speed + 0.5),
		canFly = mount.params.canFly,
		abilities = table.clone(mount.species.abilities),
	})
end

function MountService.isMounted(player: Player): boolean
	return mounts[player] ~= nil
end

-- Safe to call at any time and more than once.
function MountService.dismount(player: Player, reason: string)
	local mount = mounts[player]
	if not mount then
		return
	end
	mounts[player] = nil
	for _, connection in mount.connections do
		connection:Disconnect()
	end

	local rootCFrame = mount.rig.root.CFrame
	mount.rig.model:Destroy() -- also removes the SeatWeld, constraints and billboard

	local humanoid = mount.humanoid
	local character = player.Character
	if humanoid.Parent and humanoid.Health > 0 and character then
		humanoid.Sit = false
		local yaw = select(2, rootCFrame:ToEulerAnglesYXZ())
		character:PivotTo(
			CFrame.new(rootCFrame.Position + Vector3.new(0, MountConfig.DismountLift, 0)) * CFrame.Angles(0, yaw, 0)
		)
	end

	if player.Parent == Players then
		Remotes.fire("MountState", player, { mounted = false, reason = reason })
		if reason ~= "Died" and reason ~= "CharacterRemoving" then
			task.defer(Services.PetService.spawnCompanion, player)
		end
	end
end

-- Re-applies speed after an upgrade purchase.
function MountService.refreshStats(player: Player)
	local mount = mounts[player]
	local data = Services.DataService.getData(player)
	if mount and data then
		mount.params = buildParams(mount.species, data.speedUpgradeLevel)
		sendState(mount)
	end
end

local function groundBelow(origin: Vector3, exclude: { Instance }): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	local result = workspace:Raycast(origin, Vector3.new(0, -60, 0), params)
	return if result then result.Position else origin - Vector3.new(0, 3, 0)
end

local function summon(player: Player)
	local Security = Services.RemoteSecurityService
	local pet, species = Services.PetService.getEquipped(player)
	if not pet or not species then
		return Security.fail(Codes.NotTamed, "Equip a tamed pet to ride it.")
	end
	local existing = mounts[player]
	if existing and existing.petId == pet.id then
		return Security.ok()
	end
	local now = os.clock()
	if lastSummon[player] and now - lastSummon[player] < MountConfig.SummonCooldown then
		return Security.fail(Codes.Cooldown, "Wait a moment before summoning again.")
	end
	local humanoid = Services.PlayerStateService.getHumanoid(player)
	local root = Services.PlayerStateService.getRoot(player)
	local character = player.Character
	if not humanoid or not root or not character then
		return Security.fail(Codes.NoCharacter, "You need to be alive to ride.")
	end
	MountService.dismount(player, "Resummon")
	if humanoid.SeatPart then
		humanoid.Sit = false
	end

	local look = root.CFrame.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	local ground = groundBelow(root.Position, { character, activeFolder })
	local rig = MountFactory.build(pet.species, CFrame.new(ground) * CFrame.Angles(0, yaw, 0))
	if not rig then
		return Security.fail(Codes.ConfigError, "This pet's mount model is missing.")
	end
	lastSummon[player] = now

	local data = Services.DataService.getData(player)
	local model = rig.model
	model.Name = `Mount_{player.UserId}`
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("Species", pet.species)
	model:SetAttribute("PetId", pet.id)
	RarityBillboard.attach(model, {
		displayName = species.displayName,
		rarity = pet.rarity,
		oddsText = Services.DataService.oddsText(pet.eggTier, pet.species),
		ownerName = player.DisplayName,
	})

	Services.PetService.despawnCompanion(player)
	model.Parent = activeFolder
	rig.root:SetNetworkOwner(nil)

	local mount: Mount = {
		player = player,
		petId = pet.id,
		speciesId = pet.species,
		species = species,
		rig = rig,
		humanoid = humanoid,
		state = MountPhysics.newState(yaw),
		params = buildParams(species, if data then data.speedUpgradeLevel else 0),
		input = MountPhysics.emptyInput(),
		inputAt = 0,
		seated = false,
		spawnedAt = now,
		connections = {},
	}
	mounts[player] = mount

	table.insert(mount.connections, rig.seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = rig.seat.Occupant
		if occupant == humanoid then
			mount.seated = true
			rig.root:SetNetworkOwner(nil)
		elseif occupant ~= nil then
			-- Nobody else may ride this mount.
			occupant.Sit = false
		elseif mount.seated and mounts[player] == mount then
			MountService.dismount(player, "LeftSeat")
		end
	end))
	table.insert(mount.connections, humanoid.Died:Connect(function()
		MountService.dismount(player, "Died")
	end))

	rig.seat:Sit(humanoid)
	sendState(mount)
	return Security.ok()
end

-- Movement intent validators: reject absurd values outright, clamp small overshoot.
local function axis(value: any): (boolean, any)
	if not Validate.isFinite(value) or math.abs(value) > 1.5 then
		return false, nil
	end
	return true, math.clamp(value, -1, 1)
end

local function onInput(player: Player, forward: number, turn: number, vertical: number, jump: boolean)
	local mount = mounts[player]
	if not mount then
		return
	end
	mount.input = MountPhysics.sanitizeInput(forward, turn, vertical, jump)
	mount.inputAt = os.clock()
end

local exclusionCache: { [Player]: RaycastParams } = {}

local function rayParamsFor(mount: Mount): RaycastParams
	local params = exclusionCache[mount.player]
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		exclusionCache[mount.player] = params
	end
	local exclude: { Instance } = { mount.rig.model, activeFolder }
	if mount.player.Character then
		table.insert(exclude, mount.player.Character)
	end
	local pets = workspace:FindFirstChild("ActivePets")
	if pets then
		table.insert(exclude, pets)
	end
	params.FilterDescendantsInstances = exclude
	return params
end

local function stepMount(mount: Mount, dt: number, now: number)
	local rig = mount.rig
	local root = rig.root
	if not root.Parent then
		MountService.dismount(mount.player, "Destroyed")
		return
	end
	if root.Position.Y < workspace.FallenPartsDestroyHeight + MountConfig.Sanity.KillHeightMargin then
		MountService.dismount(mount.player, "OutOfWorld")
		return
	end
	-- The rider must actually be seated shortly after summoning.
	if not mount.seated and now - mount.spawnedAt > 1.5 then
		MountService.dismount(mount.player, "SeatFailed")
		return
	end

	local input = if now - mount.inputAt <= MountConfig.InputStaleSeconds then mount.input else MountPhysics.emptyInput()

	local position = root.Position
	local result = workspace:Raycast(position, Vector3.new(0, -(MountConfig.MaxFlightAltitude + 60), 0), rayParamsFor(mount))
	local height = if result then (position.Y - rig.radius) - result.Position.Y else math.huge
	local zone = ZoneRegistry.getZoneAtFlat(position)
	local env: MountPhysics.Env = {
		grounded = height <= 0.6,
		heightAboveGround = height,
		flightAllowed = zone == nil or zone.allowFlight,
		ceilingReached = position.Y >= ZoneConfig.WorldCeilingY,
		verticalVelocity = root.AssemblyLinearVelocity.Y,
	}

	local out = MountPhysics.step(mount.state, input, mount.params, env, dt)
	local velocityConstraint = rig.linearVelocity
	if out.flying then
		if mount.flyingMode ~= true then
			velocityConstraint.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
			mount.flyingMode = true
		end
		velocityConstraint.VectorVelocity = out.velocity
	else
		if mount.flyingMode ~= false then
			velocityConstraint.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
			mount.flyingMode = false
		end
		velocityConstraint.PlaneVelocity = out.planarVelocity
		if out.jumpVelocity then
			local v = root.AssemblyLinearVelocity
			root.AssemblyLinearVelocity = Vector3.new(v.X, out.jumpVelocity, v.Z)
		end
	end
	rig.alignOrientation.CFrame = out.orientation

	-- Sanity: ownership must stay on the server, and measured speed may not exceed the cap.
	if root:GetNetworkOwner() ~= nil then
		Services.RemoteSecurityService.report(mount.player, "Mount", "network owner changed; reclaiming")
		root:SetNetworkOwner(nil)
	end
	local v = root.AssemblyLinearVelocity
	local flat = Vector3.new(v.X, 0, v.Z)
	local tolerance = MountConfig.Sanity.SpeedTolerance
	local maxFlat = mount.params.speed * tolerance + 5
	local maxUp = math.max(mount.params.jumpVelocity, mount.params.ascendSpeed) * tolerance + 5
	if flat.Magnitude > maxFlat or v.Y > maxUp then
		local clampedFlat = if flat.Magnitude > maxFlat then flat.Unit * maxFlat else flat
		root.AssemblyLinearVelocity = Vector3.new(clampedFlat.X, math.min(v.Y, maxUp), clampedFlat.Z)
	end
end

function MountService.init(services)
	Services = services
	activeFolder = AssetLibrary.workspaceFolder("ActiveMounts")
end

function MountService.start()
	local Security = Services.RemoteSecurityService
	Security.bindFunction("SummonMount", { action = "SummonMount", args = {} }, summon)
	Security.bindFunction("Dismount", { action = "Dismount", args = {} }, function(player)
		MountService.dismount(player, "Requested")
		return Security.ok()
	end)
	Security.bindEvent(
		"MountInput",
		{ action = "MountInput", args = { axis, axis, axis, Validate.boolean() }, lock = false },
		onInput
	)

	local function hookCharacter(player: Player)
		player.CharacterRemoving:Connect(function()
			MountService.dismount(player, "CharacterRemoving")
		end)
	end
	Players.PlayerAdded:Connect(hookCharacter)
	for _, player in Players:GetPlayers() do
		hookCharacter(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		MountService.dismount(player, "PlayerLeft")
		lastSummon[player] = nil
		exclusionCache[player] = nil
	end)
	Services.DataService.ProfileReleasing:Connect(function(player)
		MountService.dismount(player, "PlayerLeft")
	end)

	RunService.Heartbeat:Connect(function(dt)
		if next(mounts) == nil then
			return
		end
		local now = os.clock()
		for _, mount in mounts do
			local ok, err = pcall(stepMount, mount, dt, now)
			if not ok then
				warn(`[Mount] step failed for {mount.player.Name}: {err}`)
				MountService.dismount(mount.player, "Error")
			end
		end
	end)

	-- Orphan sweep: any mount model without a live record is destroyed.
	task.spawn(function()
		while true do
			task.wait(10)
			local live: { [Instance]: boolean } = {}
			for _, mount in mounts do
				live[mount.rig.model] = true
			end
			for _, child in activeFolder:GetChildren() do
				if not live[child] then
					warn(`[Mount] Removing orphaned mount {child.Name}`)
					child:Destroy()
				end
			end
		end
	end)
end

return MountService
