--!strict
--[[
	ModelFactory
	Path: ServerScriptService.Server.Systems.ModelFactory

	Builds every runtime model. Each builder first looks for an art asset in
	ReplicatedStorage.Assets and clones it; if none exists it builds an original,
	low-poly procedural model so the game is fully playable without any uploads.

	Asset swap contract (no game logic changes needed):
		Assets.Enemies.<EnemyId>   Model, PrimaryPart "HumanoidRootPart"; ground enemies
		                           also need a Humanoid (HipHeight set). Crows: no Humanoid.
		Assets.Crops.<CropId>      Model with PrimaryPart at the soil line, built at ripe
		                           size (scaled down per growth stage with Model:ScaleTo).
		Assets.Weapons.<WeaponId>  Tool with a Handle.
		Assets.Defenses.<Id>       (optional folder) Model, PrimaryPart "Base"; sentries
		                           may contain a part named "Head" that turns to aim.
		Assets.Effects.*           consumed by the client EffectsController.

	Dependencies: Palette, CollisionGroup, CollisionGroups

	API:
		ModelFactory.CreateEnemy(definition) -> Model
		ModelFactory.CreateCropVisual(definition, scale) -> Model
		ModelFactory.CreateCore(radius) -> Model
		ModelFactory.CreateChest() -> Model
		ModelFactory.CreateDoor() -> Model
		ModelFactory.CreateDefense(definition) -> Model
		ModelFactory.CreateWeaponTool(definition) -> Tool
		ModelFactory.ApplyCostume(character, classDefinition)
		ModelFactory.Part(props) -> Part        -- shared helper for MapBuilder
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Palette = require(Shared.Data.Palette)

local ModelFactory = {}

local UPRIGHT_CYLINDER = CFrame.Angles(0, 0, math.rad(90))

-- Generic part constructor with sensible defaults for decorative geometry.
function ModelFactory.Part(props: { [string]: any }): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(part :: any)[key] = value
	end
	return part
end

local function ellipsoid(props: { [string]: any }): Part
	local part = ModelFactory.Part(props)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
	return part
end

local function wedge(props: { [string]: any }): WedgePart
	local part = Instance.new("WedgePart")
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.Material = Enum.Material.SmoothPlastic
	for key, value in props do
		(part :: any)[key] = value
	end
	return part
end

local function weld(part0: BasePart, part1: BasePart)
	local constraint = Instance.new("WeldConstraint")
	constraint.Part0 = part0
	constraint.Part1 = part1
	constraint.Parent = part1
end

local function findAsset(folderName: string, assetName: string): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local folder = assets and assets:FindFirstChild(folderName)
	return folder and folder:FindFirstChild(assetName)
end

-- Makes every part of a procedurally built rig unanchored, welded to the root and
-- massless (except the root, whose mass the Humanoid needs).
local function rigToRoot(model: Model, root: BasePart)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= root then
			weld(root, descendant)
			descendant.Anchored = false
			descendant.Massless = true
			descendant.CanCollide = false
		end
	end
	root.Anchored = false
end

-- Enemy rigs ------------------------------------------------------------------------

type RigParts = {
	Model: Model,
	Root: Part,
	Torso: Part,
	Head: Part,
	LeftArm: Part,
	RightArm: Part,
	Scale: number,
}

-- A simple humanoid-shaped rig standing on y = 0 with the HumanoidRootPart at hip
-- height. Arms can be posed forward (zombie stance).
local function buildBiped(name: string, visual: any, armsForward: boolean): RigParts
	local s = visual.Scale or 1
	local model = Instance.new("Model")
	model.Name = name

	local legHeight = 2 * s
	local root = ModelFactory.Part({
		Name = "HumanoidRootPart",
		Size = Vector3.new(2, 2, 1) * s,
		CFrame = CFrame.new(0, legHeight + s, 0),
		Transparency = 1,
		CanCollide = true,
		Parent = model,
	})

	local torso = ModelFactory.Part({
		Name = "Torso",
		Size = Vector3.new(2, 2, 1) * s,
		CFrame = root.CFrame,
		Color = visual.ShirtColor,
		Parent = model,
	})
	local head = ModelFactory.Part({
		Name = "Head",
		Size = Vector3.new(1.4, 1.4, 1.4) * s,
		CFrame = root.CFrame * CFrame.new(0, 1.75 * s, 0),
		Color = visual.SkinColor,
		Parent = model,
	})
	for side = -1, 1, 2 do
		ModelFactory.Part({
			Name = if side < 0 then "LeftLeg" else "RightLeg",
			Size = Vector3.new(0.9, 2, 0.9) * s,
			CFrame = CFrame.new(0.5 * side * s, legHeight / 2, 0),
			Color = visual.PantsColor,
			Parent = model,
		})
		-- Glowing eyes keep enemies readable at a distance.
		ModelFactory.Part({
			Name = "Eye",
			Size = Vector3.new(0.25, 0.25, 0.1) * s,
			CFrame = head.CFrame * CFrame.new(0.3 * side * s, 0.15 * s, -0.71 * s),
			Color = Color3.fromRGB(255, 240, 120),
			Material = Enum.Material.Neon,
			Parent = model,
		})
	end

	local armOffset = if armsForward
		then CFrame.new(0, 0.6 * s, -0.9 * s) * CFrame.Angles(math.rad(90), 0, 0)
		else CFrame.new(0, 0, 0)
	local leftArm = ModelFactory.Part({
		Name = "LeftArm",
		Size = Vector3.new(0.8, 2, 0.8) * s,
		CFrame = root.CFrame * CFrame.new(-1.4 * s, 0, 0) * armOffset,
		Color = visual.SkinColor,
		Parent = model,
	})
	local rightArm = ModelFactory.Part({
		Name = "RightArm",
		Size = Vector3.new(0.8, 2, 0.8) * s,
		CFrame = root.CFrame * CFrame.new(1.4 * s, 0, 0) * armOffset,
		Color = visual.SkinColor,
		Parent = model,
	})

	return {
		Model = model,
		Root = root,
		Torso = torso,
		Head = head,
		LeftArm = leftArm,
		RightArm = rightArm,
		Scale = s,
	}
end

local function addHumanoid(rig: RigParts)
	local humanoid = Instance.new("Humanoid")
	-- R15 rig type makes the Humanoid honour HipHeight on a custom (jointless) rig;
	-- R6 would look for leg parts to stand on instead.
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.HipHeight = 2 * rig.Scale
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.AutomaticScalingEnabled = false
	humanoid.Parent = rig.Model
end

local function decorateZombie(rig: RigParts, visual: any)
	local s = rig.Scale
	ModelFactory.Part({
		Name = "HatBrim",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, 2.6, 2.6) * s,
		CFrame = rig.Head.CFrame * CFrame.new(0, 0.75 * s, 0) * UPRIGHT_CYLINDER,
		Color = visual.HatColor,
		Material = Enum.Material.Fabric,
		Parent = rig.Model,
	})
	ModelFactory.Part({
		Name = "HatTop",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.8, 1.4, 1.4) * s,
		CFrame = rig.Head.CFrame * CFrame.new(0, 1.2 * s, 0) * UPRIGHT_CYLINDER,
		Color = visual.HatColor,
		Material = Enum.Material.Fabric,
		Parent = rig.Model,
	})
	-- Pitchfork in the right hand.
	ModelFactory.Part({
		Name = "Pitchfork",
		Size = Vector3.new(0.25, 0.25, 4) * s,
		CFrame = rig.RightArm.CFrame * CFrame.new(0, -0.9 * s, -1.2 * s),
		Color = Palette.Wood,
		Parent = rig.Model,
	})
end

local function decorateMole(rig: RigParts, visual: any)
	local s = rig.Scale
	rig.Head.Size = Vector3.new(1.8, 1.4, 1.8) * s
	rig.Torso.Size = Vector3.new(2.6, 2.2, 1.8) * s
	rig.Torso.Color = visual.SkinColor
	ellipsoid({
		Name = "Snout",
		Size = Vector3.new(0.7, 0.6, 0.9) * s,
		CFrame = rig.Head.CFrame * CFrame.new(0, -0.2 * s, -1 * s),
		Color = Color3.fromRGB(255, 150, 170),
		Parent = rig.Model,
	})
	ModelFactory.Part({
		Name = "MiningHelmet",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(2, 2, 2) * s,
		CFrame = rig.Head.CFrame * CFrame.new(0, 0.5 * s, 0),
		Color = visual.HatColor,
		Parent = rig.Model,
	})
	local lamp = ModelFactory.Part({
		Name = "Lamp",
		Size = Vector3.new(0.5, 0.5, 0.3) * s,
		CFrame = rig.Head.CFrame * CFrame.new(0, 0.9 * s, -0.95 * s),
		Color = Palette.Lantern,
		Material = Enum.Material.Neon,
		Parent = rig.Model,
	})
	local light = Instance.new("SpotLight")
	light.Brightness = 3
	light.Range = 16
	light.Color = Palette.Lantern
	light.Parent = lamp
	for _, arm in { rig.LeftArm, rig.RightArm } do
		wedge({
			Name = "Claw",
			Size = Vector3.new(0.9, 0.5, 1.2) * s,
			CFrame = arm.CFrame * CFrame.new(0, -1.2 * s, 0) * CFrame.Angles(math.rad(-90), 0, 0),
			Color = Color3.fromRGB(240, 230, 210),
			Parent = rig.Model,
		})
	end
end

local function decorateScarecrow(rig: RigParts, visual: any)
	local s = rig.Scale
	rig.Head.Shape = Enum.PartType.Ball
	rig.Head.Size = Vector3.new(1.8, 1.8, 1.8) * s
	rig.Head.Material = Enum.Material.Fabric
	rig.Head.Color = visual.SkinColor
	for _, arm in { rig.LeftArm, rig.RightArm } do
		arm.Color = visual.ShirtColor
		arm.Material = Enum.Material.Fabric
	end
	ModelFactory.Part({
		Name = "HatBrim",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, 3, 3) * s,
		CFrame = rig.Head.CFrame * CFrame.new(0, 0.8 * s, 0) * CFrame.Angles(0, 0, math.rad(80)),
		Color = visual.HatColor,
		Parent = rig.Model,
	})
	ModelFactory.Part({
		Name = "HatTop",
		Size = Vector3.new(1.3, 1.6, 1.3) * s,
		CFrame = rig.Head.CFrame * CFrame.new(0.1 * s, 1.5 * s, 0) * CFrame.Angles(0, 0, math.rad(-12)),
		Color = visual.HatColor,
		Parent = rig.Model,
	})
	-- Straw tufts sticking out of the sleeves.
	for side = -1, 1, 2 do
		wedge({
			Name = "Straw",
			Size = Vector3.new(0.6, 0.8, 0.8) * s,
			CFrame = rig.Torso.CFrame * CFrame.new(2.2 * side * s, 0, 0) * CFrame.Angles(0, 0, math.rad(90 * side)),
			Color = Color3.fromRGB(240, 210, 100),
			Parent = rig.Model,
		})
	end
end

local function decorateWitch(rig: RigParts, visual: any)
	local s = rig.Scale
	ModelFactory.Part({
		Name = "Robe",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(2.2, 2.6, 2.6) * s,
		CFrame = CFrame.new(0, 1.1 * s, 0) * UPRIGHT_CYLINDER,
		Color = visual.ShirtColor,
		Material = Enum.Material.Fabric,
		Parent = rig.Model,
	})
	-- Pointy hat as stacked cylinders.
	for index = 0, 3 do
		local width = (2.4 - index * 0.55) * s
		ModelFactory.Part({
			Name = "Hat",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.5 * s, width, width),
			CFrame = rig.Head.CFrame * CFrame.new(0, (0.75 + index * 0.45) * s, 0) * UPRIGHT_CYLINDER,
			Color = visual.HatColor,
			Parent = rig.Model,
		})
	end
	ModelFactory.Part({
		Name = "Cauldron",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1, 1, 1) * s,
		CFrame = rig.RightArm.CFrame * CFrame.new(0, -1.3 * s, 0),
		Color = Color3.fromRGB(120, 255, 140),
		Material = Enum.Material.Neon,
		Parent = rig.Model,
	})
end

local function decorateHarvester(rig: RigParts, visual: any)
	local s = rig.Scale
	rig.Head.Shape = Enum.PartType.Ball
	rig.Head.Size = Vector3.new(1.9, 1.9, 1.9) * s
	rig.Head.Color = visual.HatColor
	ModelFactory.Part({
		Name = "Hood",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(2.3, 2.3, 2.3) * s,
		CFrame = rig.Head.CFrame * CFrame.new(0, 0.2 * s, 0.25 * s),
		Color = visual.SkinColor,
		Material = Enum.Material.Fabric,
		Parent = rig.Model,
	})
	ModelFactory.Part({
		Name = "Cloak",
		Size = Vector3.new(2.6, 3.4, 1.4) * s,
		CFrame = rig.Torso.CFrame * CFrame.new(0, -0.6 * s, 0.2 * s),
		Color = visual.ShirtColor,
		Material = Enum.Material.Fabric,
		Parent = rig.Model,
	})
	local shaft = ModelFactory.Part({
		Name = "ScytheShaft",
		Size = Vector3.new(0.35, 7, 0.35) * s,
		CFrame = rig.RightArm.CFrame * CFrame.new(0, 0.5 * s, -0.6 * s),
		Color = Palette.Wood,
		Parent = rig.Model,
	})
	wedge({
		Name = "ScytheBlade",
		Size = Vector3.new(0.15, 1.2, 4) * s,
		CFrame = shaft.CFrame * CFrame.new(0, 3.3 * s, -2 * s),
		Color = Color3.fromRGB(220, 220, 235),
		Material = Enum.Material.Metal,
		Parent = rig.Model,
	})
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 90, 30)
	glow.Range = 24
	glow.Brightness = 2
	glow.Parent = rig.Head
end

local function buildCrow(name: string, visual: any): Model
	local s = visual.Scale or 1
	local model = Instance.new("Model")
	model.Name = name
	local root = ModelFactory.Part({
		Name = "HumanoidRootPart",
		Size = Vector3.new(1.6, 1.2, 2.6) * s,
		CFrame = CFrame.new(0, 0, 0),
		Color = visual.SkinColor,
		Parent = model,
	})
	ModelFactory.Part({
		Name = "Head",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1.2, 1.2, 1.2) * s,
		CFrame = CFrame.new(0, 0.4 * s, -1.5 * s),
		Color = visual.SkinColor,
		Parent = model,
	})
	wedge({
		Name = "Beak",
		Size = Vector3.new(0.4, 0.4, 0.9) * s,
		CFrame = CFrame.new(0, 0.3 * s, -2.4 * s) * CFrame.Angles(0, math.rad(180), 0),
		Color = visual.PantsColor,
		Parent = model,
	})
	for side = -1, 1, 2 do
		ModelFactory.Part({
			Name = "Wing",
			Size = Vector3.new(2.6, 0.15, 1.6) * s,
			CFrame = CFrame.new(1.9 * side * s, 0.3 * s, 0) * CFrame.Angles(0, 0, math.rad(12 * side)),
			Color = visual.SkinColor,
			Parent = model,
		})
		ModelFactory.Part({
			Name = "Eye",
			Size = Vector3.new(0.2, 0.2, 0.1) * s,
			CFrame = CFrame.new(0.3 * side * s, 0.55 * s, -2.05 * s),
			Color = visual.ShirtColor,
			Material = Enum.Material.Neon,
			Parent = model,
		})
	end
	wedge({
		Name = "Tail",
		Size = Vector3.new(1, 0.15, 1.2) * s,
		CFrame = CFrame.new(0, 0.1 * s, 1.8 * s),
		Color = visual.SkinColor,
		Parent = model,
	})
	model.PrimaryPart = root
	rigToRoot(model, root)
	return model
end

function ModelFactory.CreateEnemy(definition: any): Model
	local template = findAsset("Enemies", definition.Id)
	if template and template:IsA("Model") and template.PrimaryPart then
		local clone = template:Clone()
		clone.Name = definition.Id
		return clone
	end

	local visual = definition.Visual
	local kind = visual.Kind
	if kind == "Crow" then
		return buildCrow(definition.Id, visual)
	end

	local rig = buildBiped(definition.Id, visual, kind == "Zombie" or kind == "Mole")
	if kind == "Zombie" then
		decorateZombie(rig, visual)
	elseif kind == "Mole" then
		decorateMole(rig, visual)
	elseif kind == "Scarecrow" then
		decorateScarecrow(rig, visual)
	elseif kind == "Witch" then
		decorateWitch(rig, visual)
	elseif kind == "Harvester" then
		decorateHarvester(rig, visual)
	end
	rig.Model.PrimaryPart = rig.Root
	rigToRoot(rig.Model, rig.Root)
	addHumanoid(rig)
	return rig.Model
end

-- Crops -------------------------------------------------------------------------------

-- Builds the plant visual at `scale` (0..1 of ripe size). The model's pivot sits on
-- the soil surface so callers can PivotTo the slot position directly.
function ModelFactory.CreateCropVisual(definition: any, scale: number): Model
	local template = findAsset("Crops", definition.Id)
	if template and template:IsA("Model") and template.PrimaryPart then
		local clone = template:Clone()
		clone.Name = "Visual"
		for _, d in clone:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
			end
		end
		if scale > 0 and scale ~= 1 then
			clone:ScaleTo(scale)
		end
		return clone
	end

	local visual = definition.Visual
	local size = visual.RipeSize * math.max(scale, 0.15)
	local model = Instance.new("Model")
	model.Name = "Visual"

	local pivot = ModelFactory.Part({
		Name = "Pivot",
		Size = Vector3.new(0.2, 0.2, 0.2),
		CFrame = CFrame.new(0, 0, 0),
		Transparency = 1,
		CanQuery = false,
		Parent = model,
	})
	model.PrimaryPart = pivot

	local stemHeight = size * 0.35
	ModelFactory.Part({
		Name = "Stem",
		Size = Vector3.new(0.3, stemHeight, 0.3),
		CFrame = CFrame.new(0, stemHeight / 2, 0),
		Color = Palette.Stem,
		Parent = model,
	})
	for index = 0, 2 do
		wedge({
			Name = "Leaf",
			Size = Vector3.new(0.1, size * 0.25, size * 0.45),
			CFrame = CFrame.Angles(0, math.rad(index * 120), 0) * CFrame.new(0, size * 0.12, -size * 0.25),
			Color = Palette.Stem,
			Parent = model,
		})
	end

	local fruitParent: BasePart? = nil
	local kind = visual.Kind
	if scale >= 0.4 then
		if kind == "Star" then
			fruitParent = ModelFactory.Part({
				Name = "Fruit",
				Shape = Enum.PartType.Ball,
				Size = Vector3.one * size * 0.6,
				CFrame = CFrame.new(0, stemHeight + size * 0.3, 0),
				Color = visual.Color,
				Material = Enum.Material.Neon,
				Parent = model,
			})
			for index = 0, 4 do
				local angle = math.rad(index * 72)
				ModelFactory.Part({
					Name = "Spike",
					Shape = Enum.PartType.Ball,
					Size = Vector3.one * size * 0.22,
					CFrame = CFrame.new(0, stemHeight + size * 0.3, 0)
						* CFrame.Angles(0, angle, 0)
						* CFrame.new(0, 0, -size * 0.36),
					Color = visual.SecondaryColor,
					Material = Enum.Material.Neon,
					Parent = model,
				})
			end
		elseif kind == "Pepper" then
			fruitParent = ellipsoid({
				Name = "Fruit",
				Size = Vector3.new(size * 0.35, size * 0.8, size * 0.35),
				CFrame = CFrame.new(0, stemHeight + size * 0.3, 0) * CFrame.Angles(0, 0, math.rad(15)),
				Color = visual.Color,
				Material = Enum.Material.Glass,
				Transparency = 0.15,
				Parent = model,
			})
		elseif kind == "Corn" then
			ModelFactory.Part({
				Name = "Stalk",
				Size = Vector3.new(0.4, size, 0.4),
				CFrame = CFrame.new(0, size / 2, 0),
				Color = visual.SecondaryColor,
				Parent = model,
			})
			fruitParent = ellipsoid({
				Name = "Fruit",
				Size = Vector3.new(size * 0.25, size * 0.5, size * 0.25),
				CFrame = CFrame.new(size * 0.18, size * 0.6, 0),
				Color = visual.Color,
				Material = Enum.Material.Glass,
				Transparency = 0.3,
				Parent = model,
			})
		elseif kind == "Pumpkin" or kind == "Melon" then
			local center = CFrame.new(0, size * 0.4, 0)
			fruitParent = ellipsoid({
				Name = "Fruit",
				Size = Vector3.new(size, size * 0.8, size),
				CFrame = center,
				Color = visual.Color,
				Parent = model,
			})
			local ribs = if kind == "Pumpkin" then 4 else 3
			for index = 0, ribs - 1 do
				ellipsoid({
					Name = "Rib",
					Size = Vector3.new(size * 0.45, size * 0.82, size * 1.02),
					CFrame = center * CFrame.Angles(0, math.rad(index * (180 / ribs)), 0),
					Color = if kind == "Pumpkin" then visual.Color else visual.SecondaryColor,
					Parent = model,
				})
			end
			ModelFactory.Part({
				Name = "FruitStem",
				Size = Vector3.new(0.4, size * 0.25, 0.4),
				CFrame = center * CFrame.new(0, size * 0.45, 0),
				Color = Palette.Stem,
				Parent = model,
			})
		end
	end

	if fruitParent and visual.Glow and scale >= 1 then
		local light = Instance.new("PointLight")
		light.Color = visual.SecondaryColor
		light.Range = 10
		light.Brightness = 1.5
		light.Parent = fruitParent
	end

	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanTouch = false
		end
	end
	return model
end

-- Farm objects ---------------------------------------------------------------------

function ModelFactory.CreateCore(radius: number): Model
	local model = Instance.new("Model")
	model.Name = "GreatPumpkin"
	local size = radius * 2
	local base = ModelFactory.Part({
		Name = "Base",
		Size = Vector3.new(size * 0.7, 1, size * 0.7),
		CFrame = CFrame.new(0, 0.5, 0),
		Transparency = 1,
		Parent = model,
	})
	model.PrimaryPart = base
	local center = CFrame.new(0, size * 0.42, 0)
	local body = ellipsoid({
		Name = "Body",
		Size = Vector3.new(size, size * 0.85, size),
		CFrame = center,
		Color = Palette.PumpkinOrange,
		CanCollide = true,
		Parent = model,
	})
	for index = 0, 3 do
		ellipsoid({
			Name = "Rib",
			Size = Vector3.new(size * 0.5, size * 0.86, size * 1.02),
			CFrame = center * CFrame.Angles(0, math.rad(index * 45), 0),
			Color = Palette.PumpkinDark,
			Parent = model,
		})
	end
	ModelFactory.Part({
		Name = "Stem",
		Size = Vector3.new(1.2, size * 0.25, 1.2),
		CFrame = center * CFrame.new(0, size * 0.48, 0) * CFrame.Angles(0, 0, math.rad(10)),
		Color = Palette.Stem,
		Parent = model,
	})
	for side = -1, 1, 2 do
		wedge({
			Name = "Eye",
			Size = Vector3.new(0.3, size * 0.14, size * 0.14),
			CFrame = center * CFrame.new(side * size * 0.18, size * 0.08, -size * 0.49) * CFrame.Angles(0, math.rad(90), 0),
			Color = Palette.Lantern,
			Material = Enum.Material.Neon,
			Parent = model,
		})
	end
	local light = Instance.new("PointLight")
	light.Color = Palette.Lantern
	light.Range = 30
	light.Brightness = 2
	light.Parent = body
	return model
end

function ModelFactory.CreateChest(): Model
	local model = Instance.new("Model")
	model.Name = "HarvestChest"
	local base = ModelFactory.Part({
		Name = "Base",
		Size = Vector3.new(6, 3, 4),
		CFrame = CFrame.new(0, 1.5, 0),
		Color = Palette.Wood,
		Material = Enum.Material.WoodPlanks,
		CanCollide = true,
		Parent = model,
	})
	model.PrimaryPart = base
	ModelFactory.Part({
		Name = "Lid",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(6, 4, 4),
		CFrame = CFrame.new(0, 3, 0),
		Color = Palette.Wood,
		Material = Enum.Material.WoodPlanks,
		Parent = model,
	})
	for _, x in { -2.2, 2.2 } do
		ModelFactory.Part({
			Name = "Band",
			Size = Vector3.new(0.4, 5.1, 4.1),
			CFrame = CFrame.new(x, 2.5, 0),
			Color = Palette.Coin,
			Material = Enum.Material.Metal,
			Parent = model,
		})
	end
	ModelFactory.Part({
		Name = "Lock",
		Size = Vector3.new(0.8, 1, 0.3),
		CFrame = CFrame.new(0, 2.6, -2.1),
		Color = Palette.Coin,
		Material = Enum.Material.Neon,
		Parent = model,
	})
	return model
end

function ModelFactory.CreateDoor(): Model
	local model = Instance.new("Model")
	model.Name = "EscapeDoor"
	local base = ModelFactory.Part({
		Name = "Base",
		Size = Vector3.new(12, 1, 4),
		CFrame = CFrame.new(0, 0.5, 0),
		Color = Palette.Stone,
		Material = Enum.Material.Slate,
		CanCollide = true,
		Parent = model,
	})
	model.PrimaryPart = base
	for _, x in { -5, 5 } do
		ModelFactory.Part({
			Name = "Pillar",
			Size = Vector3.new(2, 12, 2.5),
			CFrame = CFrame.new(x, 7, 0),
			Color = Palette.Stone,
			Material = Enum.Material.Slate,
			CanCollide = true,
			Parent = model,
		})
	end
	ModelFactory.Part({
		Name = "Lintel",
		Size = Vector3.new(13, 2, 3),
		CFrame = CFrame.new(0, 14, 0),
		Color = Palette.Stone,
		Material = Enum.Material.Slate,
		Parent = model,
	})
	local portal = ModelFactory.Part({
		Name = "Portal",
		Size = Vector3.new(8, 12, 0.4),
		CFrame = CFrame.new(0, 7, 0),
		Color = Palette.AlienPurple,
		Material = Enum.Material.Neon,
		Transparency = 0.25,
		Parent = model,
	})
	local light = Instance.new("PointLight")
	light.Color = Palette.AlienPurple
	light.Range = 28
	light.Brightness = 3
	light.Parent = portal
	local particles = Instance.new("ParticleEmitter")
	particles.Color = ColorSequence.new(Palette.AlienPurple, Palette.AlienTeal)
	particles.LightEmission = 1
	particles.Rate = 30
	particles.Lifetime = NumberRange.new(0.8, 1.6)
	particles.Speed = NumberRange.new(2, 5)
	particles.SpreadAngle = Vector2.new(40, 40)
	particles.Size = NumberSequence.new(0.6, 0)
	particles.Parent = portal
	-- Two attachments carry the two decision prompts side by side.
	for name, x in { EscapeAnchor = -2.5, ContinueAnchor = 2.5 } do
		local attachment = Instance.new("Attachment")
		attachment.Name = name
		attachment.Position = Vector3.new(x, -3, -0.5)
		attachment.Parent = portal
	end
	return model
end

-- Defenses ----------------------------------------------------------------------------

function ModelFactory.CreateDefense(definition: any): Model
	local template = findAsset("Defenses", definition.Id)
	if template and template:IsA("Model") and template.PrimaryPart then
		local clone = template:Clone()
		clone.Name = definition.Id
		return clone
	end

	local model = Instance.new("Model")
	model.Name = definition.Id
	local material = (Enum.Material :: any)[definition.Material] or Enum.Material.SmoothPlastic
	local size: Vector3 = definition.Size

	if definition.Kind == "Barricade" then
		local base = ModelFactory.Part({
			Name = "Base",
			Size = size,
			CFrame = CFrame.new(0, size.Y / 2, 0),
			Color = definition.Color,
			Material = material,
			CanCollide = true,
			Parent = model,
		})
		model.PrimaryPart = base
		for _, x in { -size.X / 2 + 0.6, size.X / 2 - 0.6 } do
			ModelFactory.Part({
				Name = "Post",
				Size = Vector3.new(1, size.Y + 1, size.Z + 0.4),
				CFrame = CFrame.new(x, (size.Y + 1) / 2, 0),
				Color = Palette.Wood,
				Material = Enum.Material.Wood,
				Parent = model,
			})
		end
		ModelFactory.Part({
			Name = "Brace",
			Size = Vector3.new(size.X * 1.05, 0.5, 0.4),
			CFrame = CFrame.new(0, size.Y / 2, -size.Z / 2 - 0.2) * CFrame.Angles(0, 0, math.rad(25)),
			Color = Palette.Wood,
			Material = Enum.Material.Wood,
			Parent = model,
		})
	else
		local base = ModelFactory.Part({
			Name = "Base",
			Size = Vector3.new(size.X, size.Y * 0.55, size.Z),
			CFrame = CFrame.new(0, size.Y * 0.275, 0),
			Color = Palette.Stone,
			Material = Enum.Material.Slate,
			CanCollide = true,
			Parent = model,
		})
		model.PrimaryPart = base
		local headSize = size.X * 0.9
		local head = ModelFactory.Part({
			Name = "Head",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * headSize,
			CFrame = CFrame.new(0, size.Y * 0.55 + headSize / 2, 0),
			Color = definition.Color,
			Material = material,
			Parent = model,
		})
		if definition.SentryType == "Bolt" then
			ModelFactory.Part({
				Name = "Barrel",
				Size = Vector3.new(0.7, 0.7, headSize * 0.8),
				CFrame = head.CFrame * CFrame.new(0, 0, -headSize * 0.5),
				Color = Palette.Stem,
				Parent = model,
			})
		end
		local light = Instance.new("PointLight")
		light.Color = definition.Color
		light.Range = 12
		light.Parent = head
	end
	return model
end

-- Weapons / costumes ------------------------------------------------------------------

function ModelFactory.CreateWeaponTool(definition: any): Tool
	local template = findAsset("Weapons", definition.Id)
	if template and template:IsA("Tool") then
		local clone = template:Clone()
		clone.CanBeDropped = false
		return clone
	end

	local tool = Instance.new("Tool")
	tool.Name = definition.DisplayName
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool.Grip = CFrame.new(0, 0, -1.5)

	local visual = definition.Visual
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.35, 0.35, 5)
	handle.Color = visual.Color
	handle.Material = Enum.Material.Wood
	handle.CanCollide = false
	handle.Massless = true
	handle.CFrame = CFrame.new()
	handle.Parent = tool

	if visual.Kind == "Staff" then
		local orb = Instance.new("Part")
		orb.Name = "Orb"
		orb.Shape = Enum.PartType.Ball
		orb.Size = Vector3.new(1, 1, 1)
		orb.Color = visual.GlowColor
		orb.Material = Enum.Material.Neon
		orb.CanCollide = false
		orb.Massless = true
		orb.CFrame = handle.CFrame * CFrame.new(0, 0, 2.8)
		orb.Parent = tool
		weld(handle, orb)
		local light = Instance.new("PointLight")
		light.Color = visual.GlowColor
		light.Range = 10
		light.Parent = orb
	else
		local blade = Instance.new("WedgePart")
		blade.Name = "Blade"
		blade.Size = Vector3.new(0.15, 1, 3.4)
		blade.Color = Color3.fromRGB(225, 225, 240)
		blade.Material = Enum.Material.Metal
		blade.CanCollide = false
		blade.Massless = true
		blade.CFrame = handle.CFrame * CFrame.new(0, 0.6, 2.3) * CFrame.Angles(math.rad(-90), 0, 0)
		blade.Parent = tool
		weld(handle, blade)
		local edge = Instance.new("Part")
		edge.Name = "Edge"
		edge.Size = Vector3.new(0.2, 0.15, 3)
		edge.Color = visual.GlowColor
		edge.Material = Enum.Material.Neon
		edge.CanCollide = false
		edge.Massless = true
		edge.CFrame = handle.CFrame * CFrame.new(0, 2.1, 2.5) * CFrame.Angles(math.rad(90), 0, 0)
		edge.Parent = tool
		weld(handle, edge)
	end
	return tool
end

local COSTUME_HAT_NAME = "PF_CostumeHat"

function ModelFactory.ApplyCostume(character: Model, classDefinition: any)
	local costume = classDefinition.Costume
	local bodyColors = character:FindFirstChildOfClass("BodyColors")
	if bodyColors == nil then
		bodyColors = Instance.new("BodyColors")
		bodyColors.Parent = character
	end
	local colors = bodyColors :: BodyColors
	colors.TorsoColor3 = costume.PrimaryColor
	colors.LeftLegColor3 = costume.SecondaryColor
	colors.RightLegColor3 = costume.SecondaryColor
	colors.LeftArmColor3 = costume.PrimaryColor
	colors.RightArmColor3 = costume.PrimaryColor

	local previous = character:FindFirstChild(COSTUME_HAT_NAME)
	if previous then
		previous:Destroy()
	end
	local head = character:FindFirstChild("Head")
	if head == nil or not head:IsA("BasePart") then
		return
	end

	local hat = Instance.new("Model")
	hat.Name = COSTUME_HAT_NAME
	local parts = {}
	if costume.Hat == "WitchHat" then
		for index = 0, 4 do
			local width = 3.2 - index * 0.65
			table.insert(
				parts,
				ModelFactory.Part({
					Name = "HatTier",
					Shape = Enum.PartType.Cylinder,
					Size = Vector3.new(if index == 0 then 0.2 else 0.6, width, width),
					CFrame = head.CFrame * CFrame.new(0, 0.6 + index * 0.5, 0) * UPRIGHT_CYLINDER,
					Color = if index == 1 then costume.AccentColor else costume.PrimaryColor,
					Parent = hat,
				})
			)
		end
	else
		table.insert(
			parts,
			ModelFactory.Part({
				Name = "Helmet",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(1.6, 1.6, 1.6),
				CFrame = head.CFrame * CFrame.new(0, 0.25, 0),
				Color = costume.PrimaryColor,
				Material = Enum.Material.Metal,
				Parent = hat,
			})
		)
		table.insert(
			parts,
			ModelFactory.Part({
				Name = "Plume",
				Size = Vector3.new(0.3, 0.9, 1.4),
				CFrame = head.CFrame * CFrame.new(0, 1.2, 0.2),
				Color = costume.AccentColor,
				Material = Enum.Material.Neon,
				Parent = hat,
			})
		)
	end
	for _, part in parts do
		part.Anchored = false
		part.Massless = true
		part.CanQuery = false
		weld(head :: BasePart, part)
	end
	hat.Parent = character
end

return ModelFactory
