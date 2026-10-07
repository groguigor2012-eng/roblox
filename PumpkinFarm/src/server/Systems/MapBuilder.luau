--!strict
--[[
	MapBuilder
	Path: ServerScriptService.Server.Systems.MapBuilder

	Builds the lobby and match arenas and returns a layout table describing every
	gameplay-relevant point (plots, slots, spawns, gates, chest, core, door). Gameplay
	code only ever reads the layout, never searches the workspace, so a hand-built map
	can replace the procedural one by producing the same layout.

	Art override: if ServerStorage.Maps.FarmArena (Model) exists it is cloned instead
	of the procedural props. It must contain a Folder "Ground" (diggable floor parts
	with attribute Diggable=true and obstacles with NoDig=true); plots/slots are still
	generated procedurally from MatchConfig.Farm so validation stays consistent.

	Folder layout produced under the match folder:
		Map/Ground   floor, soil, plots, foundations, rocks (raycast set for the Mole router)
		Map/Props    fences, decorations, slot markers, invisible walls

	Dependencies: MatchConfig, Palette, Attributes, ModelFactory

	API:
		MapBuilder.ConfigureLighting()
		MapBuilder.BuildLobby(parent) -> LobbyLayout
		MapBuilder.BuildArena(parent, origin) -> ArenaLayout
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local MatchConfig = require(Shared.Config.MatchConfig)
local Palette = require(Shared.Data.Palette)

local Server = script:FindFirstAncestor("Server") :: Instance
local ModelFactory = require(Server.Systems.ModelFactory)

local Part = ModelFactory.Part
local UPRIGHT_CYLINDER = CFrame.Angles(0, 0, math.rad(90))

export type SlotLayout = { Index: number, Position: Vector3, Part: BasePart }
export type PlotLayout = { Id: string, CFrame: CFrame, Size: Vector3, Part: BasePart, Slots: { SlotLayout } }
export type ArenaLayout = {
	Origin: Vector3,
	FloorY: number,
	Center: Vector3,
	HalfSize: number,
	Bounds: { MinX: number, MaxX: number, MinZ: number, MaxZ: number },
	MapFolder: Folder,
	GroundFolder: Folder,
	PropsFolder: Folder,
	Plots: { [string]: PlotLayout },
	PlotOrder: { string },
	CoreCFrame: CFrame,
	ChestCFrame: CFrame,
	DoorCFrame: CFrame,
	PlayerSpawns: { CFrame },
	EnemySpawns: { Vector3 },
	Gates: { Vector3 },
	FenceRadius: number,
}
export type LobbyLayout = {
	Folder: Folder,
	SpawnCFrame: CFrame,
	PortalPrompt: ProximityPrompt,
}

local MapBuilder = {}

local function folder(name: string, parent: Instance): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function prompt(parent: Instance, props: { [string]: any }): ProximityPrompt
	local p = Instance.new("ProximityPrompt")
	p.RequiresLineOfSight = false
	p.HoldDuration = 0.2
	p.MaxActivationDistance = 12
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

function MapBuilder.ConfigureLighting()
	Lighting.ClockTime = 17.8
	Lighting.Brightness = 2.4
	Lighting.Ambient = Color3.fromRGB(70, 50, 90)
	Lighting.OutdoorAmbient = Color3.fromRGB(150, 120, 170)
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.EnvironmentSpecularScale = 0.4
	Lighting.GlobalShadows = true

	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
	local atmo = atmosphere :: Atmosphere
	atmo.Density = 0.32
	atmo.Offset = 0.15
	atmo.Color = Color3.fromRGB(255, 170, 140)
	atmo.Decay = Color3.fromRGB(120, 70, 150)
	atmo.Glare = 0.3
	atmo.Haze = 1.6
	atmo.Parent = Lighting

	local grading = Lighting:FindFirstChild("PF_ColorCorrection") or Instance.new("ColorCorrectionEffect")
	local cc = grading :: ColorCorrectionEffect
	cc.Name = "PF_ColorCorrection"
	cc.Saturation = 0.25
	cc.Contrast = 0.08
	cc.TintColor = Color3.fromRGB(255, 244, 236)
	cc.Parent = Lighting

	local bloom = Lighting:FindFirstChild("PF_Bloom") or Instance.new("BloomEffect")
	local b = bloom :: BloomEffect
	b.Name = "PF_Bloom"
	b.Intensity = 0.6
	b.Size = 28
	b.Threshold = 0.95
	b.Parent = Lighting
end

-- Decoration -------------------------------------------------------------------------

local function giantPumpkin(parent: Instance, position: Vector3, size: number, rng: Random)
	local model = Instance.new("Model")
	model.Name = "GiantPumpkin"
	local center = CFrame.new(position + Vector3.new(0, size * 0.4, 0)) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
	local body = Part({
		Name = "Body",
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * size,
		CFrame = center,
		Color = Palette.PumpkinOrange,
		CanCollide = true,
		Parent = model,
	})
	for index = 0, 1 do
		local rib = Part({
			Name = "Rib",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * size * 0.9,
			CFrame = center * CFrame.new((index * 2 - 1) * size * 0.18, 0, 0),
			Color = Palette.PumpkinDark,
			Parent = model,
		})
		rib.CanCollide = false
	end
	Part({
		Name = "Stem",
		Size = Vector3.new(size * 0.12, size * 0.3, size * 0.12),
		CFrame = center * CFrame.new(0, size * 0.55, 0),
		Color = Palette.Stem,
		Parent = model,
	})
	model.PrimaryPart = body
	model.Parent = parent
end

local function alienTree(parent: Instance, position: Vector3, rng: Random)
	local model = Instance.new("Model")
	model.Name = "AlienTree"
	local height = rng:NextNumber(10, 18)
	local trunk = Part({
		Name = "Trunk",
		Size = Vector3.new(1.6, height, 1.6),
		CFrame = CFrame.new(position + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.rad(rng:NextNumber(-8, 8))),
		Color = Color3.fromRGB(90, 60, 110),
		Material = Enum.Material.Wood,
		CanCollide = true,
		Parent = model,
	})
	local canopyColor = if rng:NextNumber() < 0.5 then Palette.AlienPurple else Palette.AlienTeal
	for index = 0, 2 do
		Part({
			Name = "Canopy",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * (8 - index * 1.6),
			CFrame = CFrame.new(position + Vector3.new(rng:NextNumber(-2, 2), height + index * 2.2, rng:NextNumber(-2, 2))),
			Color = canopyColor,
			Material = if index == 2 then Enum.Material.Neon else Enum.Material.SmoothPlastic,
			Parent = model,
		})
	end
	model.PrimaryPart = trunk
	model.Parent = parent
end

local function lantern(parent: Instance, position: Vector3)
	local post = Part({
		Name = "LanternPost",
		Size = Vector3.new(0.6, 7, 0.6),
		CFrame = CFrame.new(position + Vector3.new(0, 3.5, 0)),
		Color = Palette.Wood,
		Parent = parent,
	})
	local lamp = Part({
		Name = "Lantern",
		Size = Vector3.new(1.4, 1.6, 1.4),
		CFrame = post.CFrame * CFrame.new(0, 4.2, 0),
		Color = Palette.Lantern,
		Material = Enum.Material.Neon,
		Parent = parent,
	})
	local light = Instance.new("PointLight")
	light.Color = Palette.Lantern
	light.Range = 20
	light.Brightness = 1.6
	light.Parent = lamp
end

local function tombstone(parent: Instance, position: Vector3, facing: Vector3)
	local cf = CFrame.lookAt(position, position + facing)
	Part({
		Name = "Tombstone",
		Size = Vector3.new(3, 4, 0.8),
		CFrame = cf * CFrame.new(0, 2, 0),
		Color = Palette.Stone,
		Material = Enum.Material.Slate,
		CanCollide = true,
		Parent = parent,
	})
	Part({
		Name = "Grave",
		Size = Vector3.new(4, 0.4, 7),
		CFrame = cf * CFrame.new(0, 0.2, -4),
		Color = Palette.SoilWet,
		Material = Enum.Material.Ground,
		Parent = parent,
	})
end

-- Lobby ----------------------------------------------------------------------------

function MapBuilder.BuildLobby(parent: Instance): LobbyLayout
	local origin = MatchConfig.Lobby.Origin
	local size = MatchConfig.Lobby.Size
	local lobby = folder("Lobby", parent)
	local rng = Random.new(7)

	Part({
		Name = "Floor",
		Size = size,
		CFrame = CFrame.new(origin - Vector3.new(0, size.Y / 2, 0)),
		Color = Palette.Grass,
		Material = Enum.Material.Grass,
		CanCollide = true,
		Parent = lobby,
	})
	Part({
		Name = "Plaza",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.4, 50, 50),
		CFrame = CFrame.new(origin + Vector3.new(0, 0.1, 0)) * UPRIGHT_CYLINDER,
		Color = Palette.Stone,
		Material = Enum.Material.Cobblestone,
		CanCollide = true,
		Parent = lobby,
	})

	-- Low walls keep players on the island.
	local half = size.X / 2
	for _, offset in { Vector3.new(half, 0, 0), Vector3.new(-half, 0, 0), Vector3.new(0, 0, half), Vector3.new(0, 0, -half) } do
		local alongX = offset.Z ~= 0
		Part({
			Name = "Wall",
			Size = if alongX then Vector3.new(size.X, 4, 2) else Vector3.new(2, 4, size.Z),
			CFrame = CFrame.new(origin + offset + Vector3.new(0, 2, 0)),
			Color = Palette.Wood,
			Material = Enum.Material.WoodPlanks,
			CanCollide = true,
			Parent = lobby,
		})
	end

	local spawnLocation = Instance.new("SpawnLocation")
	spawnLocation.Name = "LobbySpawn"
	spawnLocation.Anchored = true
	spawnLocation.Size = Vector3.new(8, 1, 8)
	spawnLocation.CFrame = CFrame.new(origin + Vector3.new(0, 0.5, 12))
	spawnLocation.Duration = 0
	spawnLocation.Neutral = true
	spawnLocation.Color = Palette.Accent
	spawnLocation.Material = Enum.Material.Neon
	spawnLocation.Transparency = 0.4
	spawnLocation.CanCollide = false
	spawnLocation.Parent = lobby

	-- Farm Portal: queue for a match.
	local portalModel = ModelFactory.CreateDoor()
	portalModel.Name = "FarmPortal"
	portalModel:PivotTo(CFrame.new(origin + Vector3.new(0, 0, -40)))
	portalModel.Parent = lobby
	local portalPart = portalModel:FindFirstChild("Portal") :: BasePart
	portalPart.Color = Palette.Accent
	local portalPrompt = prompt(portalPart, {
		Name = "JoinQueuePrompt",
		ActionText = "Join Farm Queue",
		ObjectText = "Farm Portal",
		KeyboardKeyCode = Enum.KeyCode.E,
		MaxActivationDistance = 14,
	})

	-- Wardrobe: opens the class/costume UI on the client.
	local wardrobe = Part({
		Name = "Wardrobe",
		Size = Vector3.new(6, 9, 3),
		CFrame = CFrame.new(origin + Vector3.new(32, 4.5, 0)) * CFrame.Angles(0, math.rad(-90), 0),
		Color = Palette.AlienPurple,
		Material = Enum.Material.WoodPlanks,
		CanCollide = true,
		Parent = lobby,
	})
	local wardrobePrompt = prompt(wardrobe, {
		Name = "WardrobePrompt",
		ActionText = "Open Wardrobe",
		ObjectText = "Costumes & Classes",
		KeyboardKeyCode = Enum.KeyCode.E,
	})
	wardrobePrompt:SetAttribute("OpensUI", "ClassUI")

	local upgrades = Part({
		Name = "UpgradeStand",
		Size = Vector3.new(6, 5, 3),
		CFrame = CFrame.new(origin + Vector3.new(-32, 2.5, 0)) * CFrame.Angles(0, math.rad(90), 0),
		Color = Palette.Candy,
		Material = Enum.Material.SmoothPlastic,
		CanCollide = true,
		Parent = lobby,
	})
	local upgradesPrompt = prompt(upgrades, {
		Name = "UpgradesPrompt",
		ActionText = "Candy Upgrades",
		ObjectText = "Permanent Upgrades",
		KeyboardKeyCode = Enum.KeyCode.E,
	})
	upgradesPrompt:SetAttribute("OpensUI", "UpgradeUI")

	for index = 1, 10 do
		local angle = (index / 10) * math.pi * 2
		local radius = rng:NextNumber(42, 60)
		local position = origin + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		if index % 2 == 0 then
			giantPumpkin(lobby, position, rng:NextNumber(5, 9), rng)
		else
			alienTree(lobby, position, rng)
		end
	end
	for index = 1, 6 do
		local angle = (index / 6) * math.pi * 2
		lantern(lobby, origin + Vector3.new(math.cos(angle) * 27, 0, math.sin(angle) * 27))
	end

	return {
		Folder = lobby,
		SpawnCFrame = CFrame.new(origin + Vector3.new(0, 4, 12)),
		PortalPrompt = portalPrompt,
	}
end

-- Arena ------------------------------------------------------------------------------

local function buildPlots(origin: Vector3, ground: Folder, props: Folder): ({ [string]: PlotLayout }, { string })
	local farm = MatchConfig.Farm
	local plots: { [string]: PlotLayout } = {}
	local order: { string } = {}
	for index = 1, farm.PlotCount do
		-- Offset by half a step so no plot blocks a gate axis.
		local angle = (index - 0.5) / farm.PlotCount * math.pi * 2
		local position = origin + Vector3.new(math.cos(angle) * farm.PlotRingRadius, 0.1, math.sin(angle) * farm.PlotRingRadius)
		local plotCFrame = CFrame.lookAt(position, Vector3.new(origin.X, position.Y, origin.Z))
		local plotId = `Plot{index}`
		local plotPart = Part({
			Name = plotId,
			Size = farm.PlotSize,
			CFrame = plotCFrame,
			Color = Palette.Soil,
			Material = Enum.Material.Ground,
			CanCollide = true,
			Parent = ground,
		})
		plotPart:SetAttribute(Attributes.Diggable, true)
		plotPart:SetAttribute(Attributes.PlotId, plotId)

		local slots: { SlotLayout } = {}
		local spacingX = farm.PlotSize.X / farm.SlotColumns
		local spacingZ = farm.PlotSize.Z / farm.SlotRows
		local slotIndex = 0
		for row = 1, farm.SlotRows do
			for column = 1, farm.SlotColumns do
				slotIndex += 1
				local localOffset = Vector3.new(
					(column - 0.5) * spacingX - farm.PlotSize.X / 2,
					farm.PlotSize.Y / 2,
					(row - 0.5) * spacingZ - farm.PlotSize.Z / 2
				)
				local slotPosition = plotCFrame:PointToWorldSpace(localOffset)
				local marker = Part({
					Name = `Slot{slotIndex}`,
					Size = Vector3.new(spacingX * 0.8, 0.1, spacingZ * 0.8),
					CFrame = plotCFrame.Rotation + slotPosition + Vector3.new(0, 0.05, 0),
					Color = Palette.SoilWet,
					Material = Enum.Material.Ground,
					Transparency = 0.2,
					Parent = props,
				})
				marker:SetAttribute(Attributes.PlotId, plotId)
				marker:SetAttribute(Attributes.SlotIndex, slotIndex)
				table.insert(slots, { Index = slotIndex, Position = slotPosition, Part = marker })
			end
		end

		plots[plotId] = { Id = plotId, CFrame = plotCFrame, Size = farm.PlotSize, Part = plotPart, Slots = slots }
		table.insert(order, plotId)
	end
	return plots, order
end

local function buildFence(origin: Vector3, props: Folder): { Vector3 }
	local farm = MatchConfig.Farm
	local radius = farm.FenceRadius
	local segments = 56
	local gateHalfAngle = (farm.GateWidth / 2) / radius
	local gates: { Vector3 } = {}
	for gate = 0, farm.GateCount - 1 do
		local angle = gate / farm.GateCount * math.pi * 2
		table.insert(gates, origin + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
	end

	for index = 0, segments - 1 do
		local angle = (index + 0.5) / segments * math.pi * 2
		local inGate = false
		for gate = 0, farm.GateCount - 1 do
			local gateAngle = gate / farm.GateCount * math.pi * 2
			local delta = math.abs((angle - gateAngle + math.pi) % (math.pi * 2) - math.pi)
			if delta < gateHalfAngle then
				inGate = true
				break
			end
		end
		if not inGate then
			local position = origin + Vector3.new(math.cos(angle) * radius, farm.FenceHeight / 2, math.sin(angle) * radius)
			local length = 2 * math.pi * radius / segments + 0.2
			Part({
				Name = "Fence",
				Size = Vector3.new(length, farm.FenceHeight, 0.8),
				-- lookAt points -Z at the centre, so the part's X axis runs along the ring.
				CFrame = CFrame.lookAt(position, Vector3.new(origin.X, position.Y, origin.Z)),
				Color = Palette.Wood,
				Material = Enum.Material.WoodPlanks,
				CanCollide = true,
				Parent = props,
			})
		end
	end

	for _, gatePosition in gates do
		local outward = (gatePosition - origin).Unit
		local side = Vector3.new(-outward.Z, 0, outward.X)
		for _, sign in { -1, 1 } do
			lantern(props, gatePosition + side * sign * (farm.GateWidth / 2 + 1.5))
		end
	end
	return gates
end

function MapBuilder.BuildArena(parent: Instance, origin: Vector3): ArenaLayout
	local arena = MatchConfig.Arena
	local half = arena.Size / 2
	local mapFolder = folder("Map", parent)
	local ground = folder("Ground", mapFolder)
	local props = folder("Props", mapFolder)
	local rng = Random.new(1337)

	local artOverride = ServerStorage:FindFirstChild("Maps") and (ServerStorage :: any).Maps:FindFirstChild("FarmArena")
	if artOverride and artOverride:IsA("Model") then
		local clone = artOverride:Clone()
		clone:PivotTo(CFrame.new(origin))
		local overrideGround = clone:FindFirstChild("Ground")
		if overrideGround then
			for _, child in overrideGround:GetChildren() do
				child.Parent = ground
			end
			overrideGround:Destroy()
		end
		clone.Parent = props
	else
		local floor = Part({
			Name = "Floor",
			Size = Vector3.new(arena.Size, 4, arena.Size),
			CFrame = CFrame.new(origin - Vector3.new(0, 2, 0)),
			Color = Palette.Grass,
			Material = Enum.Material.Grass,
			CanCollide = true,
			Parent = ground,
		})
		floor:SetAttribute(Attributes.Diggable, true)

		local soil = Part({
			Name = "FarmSoil",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.2, (MatchConfig.Farm.FenceRadius - 2) * 2, (MatchConfig.Farm.FenceRadius - 2) * 2),
			CFrame = CFrame.new(origin + Vector3.new(0, 0.05, 0)) * UPRIGHT_CYLINDER,
			Color = Palette.GrassDark,
			Material = Enum.Material.Ground,
			CanCollide = true,
			Parent = ground,
		})
		soil:SetAttribute(Attributes.Diggable, true)

		-- Rocks: obstacles above ground and bedrock below (moles cannot dig under them).
		for _ = 1, arena.RockCount do
			local angle = rng:NextNumber(0, math.pi * 2)
			local radius = rng:NextNumber(55, half - 30)
			local size = Vector3.new(rng:NextNumber(6, 14), rng:NextNumber(3, 7), rng:NextNumber(6, 14))
			local rock = Part({
				Name = "Rock",
				Size = size,
				CFrame = CFrame.new(origin + Vector3.new(math.cos(angle) * radius, size.Y / 2 - 0.5, math.sin(angle) * radius))
					* CFrame.Angles(0, rng:NextNumber(0, math.pi), 0),
				Color = Palette.Stone,
				Material = Enum.Material.Slate,
				CanCollide = true,
				Parent = ground,
			})
			rock:SetAttribute(Attributes.NoDig, true)
		end

		for _ = 1, arena.DecorPumpkinCount do
			local angle = rng:NextNumber(0, math.pi * 2)
			local radius = rng:NextNumber(60, half - 20)
			giantPumpkin(props, origin + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius), rng:NextNumber(4, 13), rng)
		end
		for _ = 1, arena.AlienTreeCount do
			local angle = rng:NextNumber(0, math.pi * 2)
			local radius = rng:NextNumber(65, half - 15)
			alienTree(props, origin + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius), rng)
		end
	end

	-- Invisible boundary walls (not queryable, so they never block raycasts).
	for _, offset in { Vector3.new(half, 0, 0), Vector3.new(-half, 0, 0), Vector3.new(0, 0, half), Vector3.new(0, 0, -half) } do
		local alongX = offset.Z ~= 0
		Part({
			Name = "BoundaryWall",
			Size = if alongX then Vector3.new(arena.Size, arena.WallHeight, 4) else Vector3.new(4, arena.WallHeight, arena.Size),
			CFrame = CFrame.new(origin + offset + Vector3.new(0, arena.WallHeight / 2, 0)),
			Transparency = 1,
			CanCollide = true,
			CanQuery = false,
			Parent = props,
		})
	end

	local core = MatchConfig.Core
	local foundation = Part({
		Name = "CoreFoundation",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.6, core.FoundationRadius * 2, core.FoundationRadius * 2),
		CFrame = CFrame.new(origin + Vector3.new(0, 0.2, 0)) * UPRIGHT_CYLINDER,
		Color = Palette.Stone,
		Material = Enum.Material.Cobblestone,
		CanCollide = true,
		Parent = ground,
	})
	foundation:SetAttribute(Attributes.NoDig, true)

	local chestCFrame = CFrame.new(origin + MatchConfig.Chest.Offset) * CFrame.Angles(0, math.rad(180), 0)
	local chestPad = Part({
		Name = "ChestPad",
		Size = Vector3.new(9, 0.6, 7),
		CFrame = chestCFrame + Vector3.new(0, 0.2, 0),
		Color = Palette.Stone,
		Material = Enum.Material.Slate,
		CanCollide = true,
		Parent = ground,
	})
	chestPad:SetAttribute(Attributes.NoDig, true)

	local plots, plotOrder = buildPlots(origin, ground, props)
	local gates = buildFence(origin, props)

	local enemySpawns: { Vector3 } = {}
	for index = 0, arena.EnemySpawnPoints - 1 do
		local angle = (index + 0.5) / arena.EnemySpawnPoints * math.pi * 2
		local position = origin + Vector3.new(math.cos(angle) * arena.EnemySpawnRadius, 0, math.sin(angle) * arena.EnemySpawnRadius)
		table.insert(enemySpawns, position)
		tombstone(props, position + (position - origin).Unit * 6, (origin - position).Unit)
	end

	local playerSpawns: { CFrame } = {}
	for index = 0, 5 do
		local angle = index / 6 * math.pi * 2
		local position = origin + Vector3.new(math.cos(angle) * arena.PlayerSpawnRadius, 4, math.sin(angle) * arena.PlayerSpawnRadius)
		table.insert(playerSpawns, CFrame.lookAt(position, position + (position - origin) * Vector3.new(1, 0, 1)))
	end

	return {
		Origin = origin,
		FloorY = origin.Y,
		Center = origin,
		HalfSize = half - 4,
		Bounds = {
			MinX = origin.X - half + 4,
			MaxX = origin.X + half - 4,
			MinZ = origin.Z - half + 4,
			MaxZ = origin.Z + half - 4,
		},
		MapFolder = mapFolder,
		GroundFolder = ground,
		PropsFolder = props,
		Plots = plots,
		PlotOrder = plotOrder,
		CoreCFrame = CFrame.new(origin + Vector3.new(0, 0.5, 0)),
		ChestCFrame = chestCFrame + Vector3.new(0, 0.5, 0),
		DoorCFrame = CFrame.new(origin + MatchConfig.Door.Offset) * CFrame.Angles(0, math.rad(180), 0),
		PlayerSpawns = playerSpawns,
		EnemySpawns = enemySpawns,
		Gates = gates,
		FenceRadius = MatchConfig.Farm.FenceRadius,
	}
end

return MapBuilder
