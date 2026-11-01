--!strict
-- DemoLevel (server): a small test map that exercises every SHUTTER feature.
-- It is built ONLY when Config.DEMO_LEVEL is true AND the place contains no CameraOnly
-- objects yet, so it gets out of the way as soon as you build your own level.
--
-- Layout (floor at Y = 0, spawn at Z = +60 facing -Z):
--   * A dividing wall at Z = 30 with an open doorway (left) and a HIDDEN DOOR (right).
--     Naked eye: the hidden door is plain wall (NakedEyeOnly). Camcorder: a red door appears
--     (CameraOnly) with an "Open" prompt; using it opens the passage for everyone.
--   * Behind the hidden door: a closet with a Clue and a Battery pickup (CameraOnly).
--   * A message on the wall and footprints on the floor that only the camcorder sees.
--   * A WatcherSpawn marker at Z = -80: the Watcher starts there and comes for you.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shutter"):WaitForChild("Config"))

local TAGS = Config.Tags

local DemoLevel = {}

local WALL_COLOR = Color3.fromRGB(205, 192, 122)
local FLOOR_COLOR = Color3.fromRGB(150, 132, 84)
local DOOR_COLOR = Color3.fromRGB(110, 26, 22)
local WALL_HEIGHT = 12
local WALL_THICKNESS = 2

local function part(parent: Instance, name: string, size: Vector3, position: Vector3, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.Position = position
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Wall along X between x0 and x1, centred on z.
local function wallX(parent: Instance, name: string, x0: number, x1: number, z: number)
	part(parent, name, Vector3.new(x1 - x0, WALL_HEIGHT, WALL_THICKNESS), Vector3.new((x0 + x1) / 2, WALL_HEIGHT / 2, z), WALL_COLOR)
end

-- Wall along Z between z0 and z1, centred on x.
local function wallZ(parent: Instance, name: string, z0: number, z1: number, x: number)
	part(parent, name, Vector3.new(WALL_THICKNESS, WALL_HEIGHT, z1 - z0), Vector3.new(x, WALL_HEIGHT / 2, (z0 + z1) / 2), WALL_COLOR)
end

local function prompt(parent: Instance, action: string, objectText: string)
	local p = Instance.new("ProximityPrompt")
	p.ActionText = action
	p.ObjectText = objectText
	p.MaxActivationDistance = 9
	p.HoldDuration = 0.4
	p.RequiresLineOfSight = false -- the server does its own line-of-sight check
	p.Parent = parent
end

local function pickup(parent: Instance, name: string, kind: string, position: Vector3, color: Color3)
	local item = part(parent, name, Vector3.new(1.2, 1.2, 1.2), position, color, Enum.Material.Neon)
	item.CanCollide = false
	item:SetAttribute("PickupKind", kind)
	if kind == "Battery" then
		item:SetAttribute("Amount", 40)
	end
	prompt(item, "Take", kind)
	CollectionService:AddTag(item, TAGS.CameraOnly)
	CollectionService:AddTag(item, TAGS.Pickup)
end

function DemoLevel.buildIfEmpty(): boolean
	if not Config.DEMO_LEVEL then
		return false
	end
	for _, tagged in CollectionService:GetTagged(TAGS.CameraOnly) do
		if tagged:IsDescendantOf(workspace) then
			return false -- the place already has its own SHUTTER content
		end
	end

	local root = Instance.new("Folder")
	root.Name = "ShutterDemoLevel"

	-- Floor and outer walls
	part(root, "Floor", Vector3.new(204, 1, 204), Vector3.new(0, -0.45, 0), FLOOR_COLOR, Enum.Material.Fabric)
	wallX(root, "NorthWall", -102, 102, -101)
	wallX(root, "SouthWall", -102, 102, 101)
	wallZ(root, "WestWall", -100, 100, -101)
	wallZ(root, "EastWall", -100, 100, 101)

	-- Dividing wall at Z = 30: open doorway at x -34..-26, hidden door at x 16..24
	wallX(root, "DividerWest", -100, -34, 30)
	wallX(root, "DividerMid", -26, 16, 30)
	wallX(root, "DividerEast", 24, 100, 30)
	part(root, "DoorwayLintel", Vector3.new(8, 3, WALL_THICKNESS), Vector3.new(-30, WALL_HEIGHT - 1.5, 30), WALL_COLOR)

	-- A few pillars to break line of sight on the Watcher's side
	for i, x in { -60, -15, 40, 75 } do
		part(root, "Pillar" .. i, Vector3.new(4, WALL_HEIGHT, 4), Vector3.new(x, WALL_HEIGHT / 2, -30 + (i % 2) * 25), WALL_COLOR)
	end

	-- Closet behind the hidden door (on the far side of the divider)
	wallZ(root, "ClosetWest", 14, 29, 14)
	wallZ(root, "ClosetEast", 14, 29, 26)
	wallX(root, "ClosetBack", 13, 27, 13)

	-- The hidden door: one model, two realities.
	local door = Instance.new("Model")
	door.Name = "HiddenDoor"
	local disguise = part(door, "Disguise", Vector3.new(8, WALL_HEIGHT, WALL_THICKNESS), Vector3.new(20, WALL_HEIGHT / 2, 30), WALL_COLOR)
	CollectionService:AddTag(disguise, TAGS.NakedEyeOnly) -- the wall you think is there
	local panel = part(door, "Door", Vector3.new(6, 9, 0.6), Vector3.new(20, 4.5, 31.2), DOOR_COLOR, Enum.Material.Wood)
	panel.CanCollide = false
	CollectionService:AddTag(panel, TAGS.CameraOnly) -- the door that is really there
	prompt(panel, "Open", "Door")
	door.Parent = root
	CollectionService:AddTag(door, TAGS.Door)

	pickup(root, "Clue", "Clue", Vector3.new(17.5, 1.5, 19), Color3.fromRGB(240, 230, 200))
	pickup(root, "Battery", "Battery", Vector3.new(22.5, 1.5, 19), Color3.fromRGB(120, 230, 120))

	-- Camcorder-only message on the divider (spawn side)
	local board = part(root, "Message", Vector3.new(24, 5, 0.2), Vector3.new(-62, 6.5, 31.2), Color3.new(0, 0, 0))
	board.Transparency = 1
	board.CanCollide = false
	board.CanQuery = false
	local surface = Instance.new("SurfaceGui")
	surface.Face = Enum.NormalId.Back -- faces +Z, toward the spawn
	surface.LightInfluence = 0
	surface.Parent = board
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Size = UDim2.fromScale(1, 1)
	text.Font = Enum.Font.Creepster
	text.Text = "IT ONLY MOVES WHEN YOU LOOK AWAY"
	text.TextColor3 = Color3.fromRGB(170, 10, 10)
	text.TextScaled = true
	text.Parent = surface
	CollectionService:AddTag(board, TAGS.CameraOnly)

	-- Camcorder-only footprints leading to the hidden door
	for i = 0, 7 do
		local side = if i % 2 == 0 then -0.6 else 0.6
		local print_ = part(root, "Footprint", Vector3.new(0.8, 0.05, 1.4), Vector3.new(20 + side, 0.08, 52 - i * 2.6), Color3.fromRGB(90, 10, 10))
		print_.CanCollide = false
		print_.CanQuery = false
		CollectionService:AddTag(print_, TAGS.CameraOnly)
	end

	-- Spawn and the Watcher's start
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "ShutterSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(6, 1, 6)
	spawn.Position = Vector3.new(0, 0.5, 60)
	spawn.Duration = 0
	spawn.Color = FLOOR_COLOR
	spawn.Material = Enum.Material.Fabric
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.Parent = root

	local watcherSpawn = part(root, "WatcherSpawn", Vector3.new(2, 1, 2), Vector3.new(0, 1, -80), Color3.new(0, 0, 0))
	watcherSpawn.Transparency = 1
	watcherSpawn.CanCollide = false
	watcherSpawn.CanQuery = false
	CollectionService:AddTag(watcherSpawn, TAGS.WatcherSpawn)

	root.Parent = workspace
	print("[Shutter] Demo level built (set Config.DEMO_LEVEL = false to disable)")
	return true
end

return DemoLevel
