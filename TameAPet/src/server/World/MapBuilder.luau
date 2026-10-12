-- Generates a playable test world when Workspace.Map is empty: a ground plane, one themed
-- area per zone in ZoneConfig (meadow, forest, canyon, lake, peaks), obstacles for the
-- spawner to work around, a spawn point, zone signs, a shopkeeper and world bounds.
-- A level designer can replace all of it by building their own Workspace.Map (and optionally
-- Workspace.MapZones parts); the builder then does nothing but add missing essentials.
--
-- Parts that eggs/items must never spawn on carry the attribute NoSpawn = true.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZoneConfig = require(ReplicatedStorage.Config.ZoneConfig)

local MapBuilder = {}

local SEED = 20240611

local function folder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing :: Folder
	end
	local created = Instance.new("Folder")
	created.Name = name
	created.Parent = parent
	return created
end

local function block(parent: Instance, props: { [string]: any }): BasePart
	local p = Instance.new(props.ClassName or "Part") :: BasePart
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for key, value in props do
		if key ~= "ClassName" and key ~= "NoSpawn" then
			(p :: any)[key] = value
		end
	end
	if props.NoSpawn then
		p:SetAttribute("NoSpawn", true)
	end
	p.Parent = parent
	return p
end

-- Random point inside a zone's (rotated) footprint, at ground level.
local function zonePoint(zone, rng: Random, margin: number): Vector3
	local region = zone.region
	local half = region.size / 2
	local x = rng:NextNumber(-half.X + margin, half.X - margin)
	local z = rng:NextNumber(-half.Z + margin, half.Z - margin)
	local cf = CFrame.new(region.center.X, 0, region.center.Z) * CFrame.Angles(0, math.rad(region.rotationY), 0)
	local p = cf:PointToWorldSpace(Vector3.new(x, 0, z))
	return Vector3.new(p.X, 0, p.Z)
end

local function zoneFloor(parent: Instance, zone, material: Enum.Material, color: Color3, topY: number): BasePart
	local region = zone.region
	return block(parent, {
		Name = zone.id .. "Floor",
		Size = Vector3.new(region.size.X, 2, region.size.Z),
		CFrame = CFrame.new(region.center.X, topY - 1, region.center.Z) * CFrame.Angles(0, math.rad(region.rotationY), 0),
		Material = material,
		Color = color,
	})
end

local function tree(parent: Instance, position: Vector3, rng: Random, height: number, leafColor: Color3)
	local trunkRadius = rng:NextNumber(1.5, 2.6)
	block(parent, {
		Name = "Trunk",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(height, trunkRadius * 2, trunkRadius * 2),
		CFrame = CFrame.new(position + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Material = Enum.Material.Wood,
		Color = Color3.fromRGB(110, 78, 52),
		NoSpawn = true,
	})
	local canopy = rng:NextNumber(12, 20)
	block(parent, {
		Name = "Canopy",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(canopy, canopy, canopy),
		Position = position + Vector3.new(0, height + canopy * 0.25, 0),
		Material = Enum.Material.Grass,
		Color = leafColor,
		CanQuery = false, -- spawn rays pass through leaves so eggs can hide under trees
		NoSpawn = true,
	})
end

local function rock(parent: Instance, position: Vector3, rng: Random, size: number, color: Color3)
	block(parent, {
		Name = "Rock",
		Size = Vector3.new(size, size * rng:NextNumber(0.5, 0.9), size * rng:NextNumber(0.7, 1.2)),
		CFrame = CFrame.new(position + Vector3.new(0, size * 0.25, 0))
			* CFrame.Angles(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, math.pi), rng:NextNumber(-0.3, 0.3)),
		Material = Enum.Material.Slate,
		Color = color,
	})
end

local function sign(parent: Instance, position: Vector3, title: string, subtitle: string)
	local post = block(parent, {
		Name = "ZoneSign",
		Size = Vector3.new(1, 10, 1),
		Position = position + Vector3.new(0, 5, 0),
		Material = Enum.Material.Wood,
		Color = Color3.fromRGB(120, 90, 60),
		NoSpawn = true,
	})
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(240, 60)
	gui.StudsOffset = Vector3.new(0, 7, 0)
	gui.MaxDistance = 220
	gui.LightInfluence = 0
	gui.Parent = post
	local titleLabel = Instance.new("TextLabel")
	titleLabel.BackgroundTransparency = 1
	titleLabel.Size = UDim2.new(1, 0, 0.6, 0)
	titleLabel.Font = Enum.Font.GothamBlack
	titleLabel.TextScaled = true
	titleLabel.TextColor3 = Color3.new(1, 1, 1)
	titleLabel.TextStrokeTransparency = 0.3
	titleLabel.Text = title
	titleLabel.Parent = gui
	local subLabel = titleLabel:Clone()
	subLabel.Font = Enum.Font.GothamMedium
	subLabel.Position = UDim2.fromScale(0, 0.6)
	subLabel.Size = UDim2.new(1, 0, 0.4, 0)
	subLabel.Text = subtitle
	subLabel.Parent = gui
end

-- Themes -----------------------------------------------------------------------------------

local function buildMeadow(parent: Instance, zone, rng: Random)
	zoneFloor(parent, zone, Enum.Material.Grass, Color3.fromRGB(110, 180, 80), 0.4)
	for _ = 1, 7 do
		local p = zonePoint(zone, rng, 50)
		if p.Magnitude < 70 then
			continue
		end
		local r = rng:NextNumber(40, 70)
		block(parent, {
			Name = "Hill",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(r, r, r),
			Position = p + Vector3.new(0, -r * 0.36, 0),
			Material = Enum.Material.Grass,
			Color = Color3.fromRGB(104, 176, 76),
		})
	end
	for _ = 1, 16 do
		local p = zonePoint(zone, rng, 15)
		if p.Magnitude > 60 then
			tree(parent, p, rng, rng:NextNumber(12, 18), Color3.fromRGB(80, 160, 70))
		end
	end
	for _ = 1, 30 do
		local p = zonePoint(zone, rng, 10)
		block(parent, {
			Name = "Flower",
			Size = Vector3.new(0.8, 0.8, 0.8),
			Position = p + Vector3.new(0, 0.8, 0),
			Material = Enum.Material.Neon,
			Color = Color3.fromHSV(rng:NextNumber(), 0.5, 1),
			CanCollide = false,
			CanQuery = false,
			NoSpawn = true,
		})
	end
end

local function buildForest(parent: Instance, zone, rng: Random)
	zoneFloor(parent, zone, Enum.Material.Grass, Color3.fromRGB(60, 120, 60), 0.4)
	for _ = 1, 75 do
		tree(parent, zonePoint(zone, rng, 10), rng, rng:NextNumber(18, 30), Color3.fromRGB(40, 110 + rng:NextInteger(0, 40), 50))
	end
	for _ = 1, 14 do
		local p = zonePoint(zone, rng, 20)
		block(parent, {
			Name = "Log",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(rng:NextNumber(10, 18), 3, 3),
			CFrame = CFrame.new(p + Vector3.new(0, 1.9, 0)) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0),
			Material = Enum.Material.Wood,
			Color = Color3.fromRGB(100, 70, 45),
		})
	end
	for _ = 1, 12 do
		rock(parent, zonePoint(zone, rng, 10), rng, rng:NextNumber(3, 7), Color3.fromRGB(110, 115, 110))
	end
end

local function buildCanyon(parent: Instance, zone, rng: Random)
	zoneFloor(parent, zone, Enum.Material.Sand, Color3.fromRGB(214, 160, 100), 0.4)
	for _ = 1, 11 do
		local p = zonePoint(zone, rng, 40)
		local w, d, h = rng:NextNumber(30, 60), rng:NextNumber(30, 60), rng:NextNumber(18, 55)
		local yaw = rng:NextNumber(0, math.pi)
		local base = CFrame.new(p) * CFrame.Angles(0, yaw, 0)
		block(parent, {
			Name = "Mesa",
			Size = Vector3.new(w, h, d),
			CFrame = base * CFrame.new(0, h / 2, 0),
			Material = Enum.Material.Sandstone,
			Color = Color3.fromRGB(196, 110, 70),
		})
		-- A ramp up one side so land mounts can reach the top.
		local rampLength = h * 2.2
		block(parent, {
			ClassName = "WedgePart",
			Name = "Ramp",
			Size = Vector3.new(math.min(w, 14), h, rampLength),
			CFrame = base * CFrame.new(0, h / 2, d / 2 + rampLength / 2) * CFrame.Angles(0, math.pi, 0),
			Material = Enum.Material.Sandstone,
			Color = Color3.fromRGB(205, 125, 80),
		})
	end
	for _ = 1, 25 do
		rock(parent, zonePoint(zone, rng, 10), rng, rng:NextNumber(3, 9), Color3.fromRGB(170, 100, 70))
	end
end

local function buildLake(parent: Instance, zone, rng: Random)
	zoneFloor(parent, zone, Enum.Material.Sand, Color3.fromRGB(200, 190, 150), 0.4)
	local region = zone.region
	block(parent, {
		Name = "Water",
		Size = Vector3.new(region.size.X - 40, 3, region.size.Z - 40),
		Position = Vector3.new(region.center.X, 1.9, region.center.Z),
		Material = Enum.Material.Glass,
		Color = Color3.fromRGB(60, 120, 200),
		Transparency = 0.45,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
		NoSpawn = true,
	})
	for _ = 1, 9 do
		local p = zonePoint(zone, rng, 50)
		local r = rng:NextNumber(18, 38)
		local h = rng:NextNumber(3, 7)
		block(parent, {
			Name = "Island",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(h, r * 2, r * 2),
			CFrame = CFrame.new(p + Vector3.new(0, h / 2 + 0.4, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Material = Enum.Material.Grass,
			Color = Color3.fromRGB(90, 150, 100),
		})
		if rng:NextNumber() < 0.6 then
			tree(parent, p + Vector3.new(0, h + 0.4, 0), rng, rng:NextNumber(10, 16), Color3.fromRGB(70, 140, 120))
		end
	end
end

local function buildPeaks(parent: Instance, zone, rng: Random)
	zoneFloor(parent, zone, Enum.Material.Slate, Color3.fromRGB(110, 115, 125), 0.4)
	for i = 1, 13 do
		local p = zonePoint(zone, rng, 40)
		local w = rng:NextNumber(30, 60)
		local h = if i <= 3 then rng:NextNumber(25, 45) else rng:NextNumber(60, 170)
		block(parent, {
			Name = "Plateau",
			Size = Vector3.new(w, h, w * rng:NextNumber(0.8, 1.3)),
			CFrame = CFrame.new(p + Vector3.new(0, h / 2, 0)) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0),
			Material = Enum.Material.Rock,
			Color = Color3.fromRGB(100, 104, 116),
		})
		block(parent, {
			Name = "Snow",
			Size = Vector3.new(w - 2, 1, w - 2),
			CFrame = CFrame.new(p + Vector3.new(0, h + 0.5, 0)),
			Material = Enum.Material.Snow,
			Color = Color3.fromRGB(240, 244, 255),
			CanCollide = false,
			CanQuery = false,
			NoSpawn = true,
		})
		if i <= 3 then
			local rampLength = h * 2.4
			block(parent, {
				ClassName = "WedgePart",
				Name = "Ramp",
				Size = Vector3.new(14, h, rampLength),
				CFrame = CFrame.new(p) * CFrame.new(0, h / 2, w / 2 + rampLength / 2) * CFrame.Angles(0, math.pi, 0),
				Material = Enum.Material.Rock,
				Color = Color3.fromRGB(110, 114, 126),
			})
		end
	end
	for _ = 1, 20 do
		rock(parent, zonePoint(zone, rng, 10), rng, rng:NextNumber(4, 10), Color3.fromRGB(90, 94, 104))
	end
end

local THEMES = {
	Meadow = buildMeadow,
	Forest = buildForest,
	Canyon = buildCanyon,
	Lake = buildLake,
	Peaks = buildPeaks,
}

-- Essentials (always ensured) ----------------------------------------------------------------

local function ensureSpawn()
	local worldSpawn = folder(workspace, "WorldSpawn")
	if worldSpawn:FindFirstChildWhichIsA("SpawnLocation", true) then
		return
	end
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(14, 1, 14)
	spawn.Position = Vector3.new(0, 0.9, 30)
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.Color = Color3.fromRGB(255, 210, 90)
	spawn.Neutral = true
	spawn.Duration = 0
	spawn:SetAttribute("NoSpawn", true)
	spawn.Parent = worldSpawn
end

local function ensureShopkeeper()
	local npcs = folder(workspace, "NPCs")
	if npcs:FindFirstChild("Shopkeeper") then
		return
	end
	local model = Instance.new("Model")
	model.Name = "Shopkeeper"
	local base = CFrame.new(28, 0.4, 10) * CFrame.Angles(0, math.rad(-120), 0)
	local counter = block(model, {
		Name = "Counter",
		Size = Vector3.new(10, 3.5, 3),
		CFrame = base * CFrame.new(0, 1.75, 0),
		Material = Enum.Material.Wood,
		Color = Color3.fromRGB(150, 100, 60),
		NoSpawn = true,
	})
	block(model, {
		Name = "Awning",
		Size = Vector3.new(12, 0.5, 6),
		CFrame = base * CFrame.new(0, 9, 1),
		Material = Enum.Material.Fabric,
		Color = Color3.fromRGB(230, 80, 80),
		NoSpawn = true,
	})
	for _, x in { -5.5, 5.5 } do
		block(model, {
			Name = "Pole",
			Size = Vector3.new(0.6, 9, 0.6),
			CFrame = base * CFrame.new(x, 4.5, 3.5),
			Material = Enum.Material.Wood,
			Color = Color3.fromRGB(120, 85, 55),
			NoSpawn = true,
		})
	end
	local keeper = block(model, {
		Name = "Keeper",
		Size = Vector3.new(2, 5, 1.5),
		CFrame = base * CFrame.new(0, 2.5, 3),
		Color = Color3.fromRGB(90, 140, 220),
		NoSpawn = true,
	})
	block(model, {
		Name = "KeeperHead",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(2, 2, 2),
		CFrame = base * CFrame.new(0, 6, 3),
		Color = Color3.fromRGB(255, 215, 180),
		NoSpawn = true,
	})
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ShopPrompt"
	prompt.ActionText = "Open Shop"
	prompt.ObjectText = "Compass Merchant"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	-- Purely a UI shortcut: the client opens the shop panel. Purchases still go through the
	-- validated Purchase remote.
	prompt:SetAttribute("OpensShop", true)
	prompt.Parent = counter
	model.PrimaryPart = keeper
	model.Parent = npcs
end

local function ensureBounds()
	local map = folder(workspace, "Map")
	if map:FindFirstChild("Bounds") then
		return
	end
	local bounds = folder(map, "Bounds")
	local extent = ZoneConfig.WorldHalfExtent
	local height = ZoneConfig.WorldCeilingY * 2
	for _, side in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
		local x, z = side[1], side[2]
		block(bounds, {
			Name = "Wall",
			Size = if x ~= 0 then Vector3.new(4, height, extent * 2) else Vector3.new(extent * 2, height, 4),
			Position = Vector3.new(x * extent, height / 2 - 50, z * extent),
			Transparency = 1,
			CanQuery = false,
			NoSpawn = true,
		})
	end
end

local function applyLighting()
	if not Lighting:FindFirstChildOfClass("Atmosphere") then
		local atmosphere = Instance.new("Atmosphere")
		atmosphere.Density = 0.28
		atmosphere.Haze = 1.2
		atmosphere.Color = Color3.fromRGB(200, 220, 255)
		atmosphere.Parent = Lighting
	end
end

function MapBuilder.build()
	local map = folder(workspace, "Map")
	local hasAuthoredMap = false
	for _, child in map:GetChildren() do
		if child.Name ~= "Bounds" then
			hasAuthoredMap = true
			break
		end
	end

	if not hasAuthoredMap then
		local rng = Random.new(SEED)
		local extent = ZoneConfig.WorldHalfExtent
		block(map, {
			Name = "Ground",
			Size = Vector3.new(extent * 2, 4, extent * 2),
			Position = Vector3.new(0, -2, 0),
			Material = Enum.Material.Grass,
			Color = Color3.fromRGB(96, 160, 72),
		})
		for _, zone in ZoneConfig.Zones do
			local builder = THEMES[zone.theme]
			local zoneFolder = folder(map, zone.id)
			if builder then
				builder(zoneFolder, zone, rng)
			else
				warn(`[Map] Zone "{zone.id}" has unknown theme "{zone.theme}"; it gets a plain floor`)
				zoneFloor(zoneFolder, zone, Enum.Material.Grass, Color3.fromRGB(110, 170, 90), 0.4)
			end
			-- Sign on the edge of the zone facing the world origin.
			local center = Vector3.new(zone.region.center.X, 0, zone.region.center.Z)
			local toOrigin = if center.Magnitude > 1 then -center.Unit else Vector3.new(0, 0, 1)
			local edge = math.min(zone.region.size.X, zone.region.size.Z) / 2 - 15
			local subtitle = if zone.unlock then "Pass required (Shop)" else "Open to all explorers"
			sign(zoneFolder, center + toOrigin * edge + Vector3.new(0, 0.4, 0), zone.displayName, subtitle)
		end
		print("[Map] Generated the placeholder test world")
	end

	ensureBounds()
	ensureSpawn()
	ensureShopkeeper()
	applyLighting()
end

return MapBuilder
