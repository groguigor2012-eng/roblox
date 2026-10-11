--!strict
-- Optional test course (GameConfig.DemoCourse.Mode). Original layout built
-- from plain parts in a dark ink-forest palette. It exercises every system:
--   * ~200 shards (ring, platform steps, long spiral) to load-test collectibles
--   * a wall-jump shaft with a Power Orb on top
--   * a vault whose roof is GroundPoundBreakable tiles (one needs a higher
--     drop, one needs two hits; all respawn) with Power Orbs inside
--   * a Shared respawning shard and a non-persistent shard
--   * damage and heal pads for the heart UI
-- Collectibles go under Workspace.Collectibles.DemoCourse and breakables
-- under Workspace.Destructibles.DemoCourse; the geometry under Workspace.DemoCourse.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local CollectibleConfig = require(Shared.Config.CollectibleConfig)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Utilities.Logger)

local logger = Logger.new("DemoCourse")

local INK = Color3.fromRGB(26, 29, 38)
local INK_LIGHT = Color3.fromRGB(48, 54, 68)
local PAPER = Color3.fromRGB(226, 228, 236)
local MOSS = Color3.fromRGB(46, 74, 66)
local CANOPY = Color3.fromRGB(34, 52, 50)

local ATTR = CollectibleConfig.Attributes
local DESTRUCTIBLE = GameConfig.DestructibleAttributes

local DemoCourse = {}

type PartProps = {
	Name: string,
	Size: Vector3,
	CFrame: CFrame,
	Color: Color3,
	Material: Enum.Material?,
	Shape: Enum.PartType?,
	CanCollide: boolean?,
	Parent: Instance,
}

local function makePart(props: PartProps): Part
	local part = Instance.new("Part")
	part.Name = props.Name
	part.Anchored = true
	part.Size = props.Size
	part.CFrame = props.CFrame
	part.Color = props.Color
	part.Material = props.Material or Enum.Material.SmoothPlastic
	if props.Shape then
		part.Shape = props.Shape
	end
	part.CanCollide = if props.CanCollide == nil then true else props.CanCollide
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = props.Parent
	return part
end

local function getOrCreateFolder(parent: Instance, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

type CollectibleOptions = {
	Persistent: boolean?,
	Mode: string?,
	RespawnSeconds: number?,
	Reward: number?,
}

local function makeCollectible(
	parent: Instance,
	id: string,
	currencyType: string,
	position: Vector3,
	options: CollectibleOptions?
): Part
	local isOrb = currencyType == "PowerOrbs"
	local part = Instance.new("Part")
	part.Name = id
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = CollectibleConfig.Visual.Colors[currencyType]
	if isOrb then
		part.Shape = Enum.PartType.Ball
		part.Size = Vector3.new(2.2, 2.2, 2.2)
		part.CFrame = CFrame.new(position)
		local light = Instance.new("PointLight")
		light.Color = part.Color
		light.Range = 10
		light.Brightness = 1.2
		light.Parent = part
	else
		-- A cube balanced on its corner reads as a crystal shard.
		part.Size = Vector3.new(1.1, 1.1, 1.1)
		part.CFrame = CFrame.new(position) * CFrame.Angles(math.rad(45), 0, math.rad(35.26))
	end
	part:SetAttribute(ATTR.Id, id)
	part:SetAttribute(ATTR.Type, currencyType)
	if options then
		if options.Reward then
			part:SetAttribute(ATTR.Reward, options.Reward)
		end
		if options.Persistent ~= nil then
			part:SetAttribute(ATTR.Persistent, options.Persistent)
		end
		if options.Mode then
			part:SetAttribute(ATTR.Mode, options.Mode)
		end
		if options.RespawnSeconds then
			part:SetAttribute(ATTR.RespawnSeconds, options.RespawnSeconds)
		end
	end
	part:AddTag(GameConfig.Tags.Collectible)
	part.Parent = parent
	return part
end

local function makeTree(parent: Instance, base: Vector3, height: number)
	makePart({
		Name = "Trunk",
		Size = Vector3.new(height, 1.6, 1.6),
		CFrame = CFrame.new(base + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = INK,
		Shape = Enum.PartType.Cylinder,
		Parent = parent,
	})
	makePart({
		Name = "Canopy",
		Size = Vector3.new(9, 9, 9),
		CFrame = CFrame.new(base + Vector3.new(0, height + 2, 0)),
		Color = CANOPY,
		Material = Enum.Material.Slate,
		Shape = Enum.PartType.Ball,
		CanCollide = false,
		Parent = parent,
	})
end

local function makePad(parent: Instance, name: string, position: Vector3, color: Color3, onTouch: (Humanoid) -> ())
	local pad = makePart({
		Name = name,
		Size = Vector3.new(8, 0.6, 8),
		CFrame = CFrame.new(position),
		Color = color,
		Material = Enum.Material.Neon,
		Parent = parent,
	})
	pad.CanTouch = true
	local lastTouch: { [Player]: number } = {}
	pad.Touched:Connect(function(hit: BasePart)
		local character = hit.Parent
		if not character then
			return
		end
		local player = Players:GetPlayerFromCharacter(character)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not player or not humanoid or humanoid.Health <= 0 then
			return
		end
		local now = os.clock()
		if lastTouch[player] and now - lastTouch[player] < GameConfig.DemoCourse.PadCooldown then
			return
		end
		lastTouch[player] = now
		onTouch(humanoid)
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastTouch[player] = nil
	end)
end

local function buildGround(geometry: Instance, origin: Vector3)
	makePart({
		Name = "Ground",
		Size = Vector3.new(220, 4, 220),
		CFrame = CFrame.new(origin + Vector3.new(0, -1, 0)),
		Color = MOSS,
		Material = Enum.Material.Slate,
		Parent = geometry,
	})
	local spawnLocation = Instance.new("SpawnLocation")
	spawnLocation.Name = "DemoSpawn"
	spawnLocation.Anchored = true
	spawnLocation.Neutral = true
	spawnLocation.Duration = 0
	spawnLocation.Size = Vector3.new(8, 1, 8)
	spawnLocation.CFrame = CFrame.new(origin + Vector3.new(0, 1.5, 0))
	spawnLocation.Color = PAPER
	spawnLocation.Material = Enum.Material.SmoothPlastic
	spawnLocation.Parent = geometry

	local random = Random.new(7)
	for index = 1, 18 do
		local angle = (index / 18) * math.pi * 2
		local radius = 85 + random:NextNumber(-6, 6)
		local base = origin + Vector3.new(math.cos(angle) * radius, 1, math.sin(angle) * radius)
		makeTree(geometry, base, random:NextNumber(18, 30))
	end
end

local function buildShardRing(collectibles: Instance, origin: Vector3)
	local count = 40
	for index = 1, count do
		local angle = (index / count) * math.pi * 2
		local position = origin + Vector3.new(math.cos(angle) * 18, 3.5, math.sin(angle) * 18)
		makeCollectible(collectibles, string.format("demo.ring.%02d", index), "Shards", position)
	end
end

local function buildSteps(geometry: Instance, collectibles: Instance, origin: Vector3)
	for index = 1, 6 do
		local top = origin + Vector3.new(26 + index * 9, 1 + index * 4, -36)
		makePart({
			Name = `Step{index}`,
			Size = Vector3.new(6, 1, 6),
			CFrame = CFrame.new(top - Vector3.new(0, 0.5, 0)),
			Color = INK_LIGHT,
			Parent = geometry,
		})
		for shard = 1, 3 do
			local offset = Vector3.new((shard - 2) * 1.8, 3, 0)
			makeCollectible(collectibles, string.format("demo.steps.%d.%d", index, shard), "Shards", top + offset)
		end
	end
end

local function buildWallShaft(geometry: Instance, collectibles: Instance, origin: Vector3)
	local center = origin + Vector3.new(45, 1, 20)
	local height = 34
	for _, side in { -1, 1 } do
		makePart({
			Name = "ShaftWall",
			Size = Vector3.new(2, height, 14),
			CFrame = CFrame.new(center + Vector3.new(side * 5, height / 2, 0)),
			Color = INK,
			Material = Enum.Material.Slate,
			Parent = geometry,
		})
	end
	makePart({
		Name = "ShaftTop",
		Size = Vector3.new(12, 1, 14),
		CFrame = CFrame.new(center + Vector3.new(0, height + 0.5, 0)),
		Color = PAPER,
		Parent = geometry,
	})
	makeCollectible(collectibles, "demo.orb.shaft", "PowerOrbs", center + Vector3.new(0, height + 4, 0))
	for index = 1, 6 do
		makeCollectible(
			collectibles,
			string.format("demo.shaft.%02d", index),
			"Shards",
			center + Vector3.new(0, 4 + index * 4.5, 0)
		)
	end
end

local function buildVault(geometry: Instance, collectibles: Instance, breakables: Instance, origin: Vector3)
	local center = origin + Vector3.new(-45, 1, 10)
	local inner = 24
	local wallHeight = 10
	for _, spec in {
		{ Vector3.new(0, 0, inner / 2 + 1), Vector3.new(inner + 4, wallHeight, 2) },
		{ Vector3.new(0, 0, -(inner / 2 + 1)), Vector3.new(inner + 4, wallHeight, 2) },
		{ Vector3.new(inner / 2 + 1, 0, 0), Vector3.new(2, wallHeight, inner) },
		{ Vector3.new(-(inner / 2 + 1), 0, 0), Vector3.new(2, wallHeight, inner) },
	} do
		makePart({
			Name = "VaultWall",
			Size = spec[2],
			CFrame = CFrame.new(center + spec[1] + Vector3.new(0, wallHeight / 2, 0)),
			Color = INK,
			Material = Enum.Material.Slate,
			Parent = geometry,
		})
	end

	local tiles = 4
	local tileSize = inner / tiles
	for x = 1, tiles do
		for z = 1, tiles do
			local offset = Vector3.new((x - 0.5) * tileSize - inner / 2, wallHeight - 0.5, (z - 0.5) * tileSize - inner / 2)
			local tile = makePart({
				Name = `RoofTile{x}_{z}`,
				Size = Vector3.new(tileSize, 1, tileSize),
				CFrame = CFrame.new(center + offset),
				Color = PAPER,
				Material = Enum.Material.Glass,
				Parent = breakables,
			})
			tile:SetAttribute(DESTRUCTIBLE.RespawnSeconds, 30)
			if x == 1 and z == 1 then
				tile.Color = Color3.fromRGB(150, 120, 200)
				tile:SetAttribute(DESTRUCTIBLE.MinPower, 12)
			elseif x == tiles and z == tiles then
				tile.Color = Color3.fromRGB(120, 130, 150)
				tile:SetAttribute(DESTRUCTIBLE.BreakHits, 2)
			end
			tile:AddTag(GameConfig.Tags.GroundPoundBreakable)
		end
	end
	for index, offset in { Vector3.new(-6, 2.5, -6), Vector3.new(6, 2.5, 6), Vector3.new(0, 2.5, 0) } do
		makeCollectible(collectibles, `demo.orb.vault.{index}`, "PowerOrbs", center + offset)
	end
	-- Steps up to the roof.
	for index = 1, 3 do
		makePart({
			Name = "VaultStep",
			Size = Vector3.new(6, 1, 6),
			CFrame = CFrame.new(center + Vector3.new(inner / 2 + 6 + index * 4, index * 2.6, 0)),
			Color = INK_LIGHT,
			Parent = geometry,
		})
	end
end

local function buildSpiral(collectibles: Instance, origin: Vector3)
	-- A flat spiral field north of the spawn, clear of the other structures.
	local center = origin + Vector3.new(0, 0, 62)
	local count = 120
	for index = 1, count do
		local t = index / count
		local angle = t * math.pi * 12
		local radius = 4 + t * 20
		local position = center + Vector3.new(math.cos(angle) * radius, 3.5, math.sin(angle) * radius)
		makeCollectible(collectibles, string.format("demo.spiral.%03d", index), "Shards", position)
	end
end

local function buildSpecials(geometry: Instance, collectibles: Instance, origin: Vector3)
	makeCollectible(collectibles, "demo.shared.respawning", "Shards", origin + Vector3.new(0, 3.5, 26), {
		Mode = "Shared",
		RespawnSeconds = 10,
		Reward = 5,
	})
	makeCollectible(collectibles, "demo.session.only", "Shards", origin + Vector3.new(6, 3.5, 26), {
		Persistent = false,
		Reward = 2,
	})

	local maxHealth = GameConfig.Health.MaxHealth
	makePad(geometry, "DamagePad", origin + Vector3.new(-6, 1.3, -26), Color3.fromRGB(190, 40, 52), function(humanoid)
		humanoid:TakeDamage(GameConfig.DemoCourse.DamagePadDamage)
	end)
	makePad(geometry, "HealPad", origin + Vector3.new(6, 1.3, -26), Color3.fromRGB(70, 190, 130), function(humanoid)
		humanoid.Health = math.min(maxHealth, humanoid.Health + GameConfig.DemoCourse.HealPadAmount)
	end)
end

function DemoCourse.ShouldBuild(): boolean
	local mode = GameConfig.DemoCourse.Mode
	return mode == "Always" or (mode == "StudioOnly" and RunService:IsStudio())
end

function DemoCourse.Build()
	if Workspace:FindFirstChild("DemoCourse") then
		logger:Warn("AlreadyBuilt")
		return
	end
	local origin = GameConfig.DemoCourse.Origin
	local geometry = Instance.new("Folder")
	geometry.Name = "DemoCourse"

	local collectibles = Instance.new("Folder")
	collectibles.Name = "DemoCourse"
	local breakables = Instance.new("Folder")
	breakables.Name = "DemoCourse"

	buildGround(geometry, origin)
	buildShardRing(collectibles, origin)
	buildSteps(geometry, collectibles, origin)
	buildWallShaft(geometry, collectibles, origin)
	buildVault(geometry, collectibles, breakables, origin)
	buildSpiral(collectibles, origin)
	buildSpecials(geometry, collectibles, origin)

	geometry.Parent = Workspace
	breakables.Parent = getOrCreateFolder(Workspace, GameConfig.Folders.Destructibles)
	collectibles.Parent = getOrCreateFolder(Workspace, GameConfig.Folders.Collectibles)
	logger:Info("Built", { Collectibles = #collectibles:GetChildren() })
end

return DemoCourse
