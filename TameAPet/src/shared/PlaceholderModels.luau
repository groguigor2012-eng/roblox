-- Procedural placeholder art: pets, eggs and item pickups built from parts so the game is
-- fully playable before real models exist. Used by the server for world objects and by the
-- client for UI previews. Replace any of them by putting a model with the same id in
-- ServerStorage.{PetModels, MountModels, EggModels, ItemModels} (server) or
-- ReplicatedStorage.UIAssets.PetPreviews (client previews).
--
-- All builders return an unanchored Model whose parts are welded to its PrimaryPart and have
-- CanCollide/CanQuery/CanTouch disabled. Callers decide anchoring and placement.

local PlaceholderModels = {}

local function part(props: { [string]: any }): BasePart
	local className = props.ClassName or "Part"
	local p = Instance.new(className) :: BasePart
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = true
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		if key ~= "ClassName" then
			(p :: any)[key] = value
		end
	end
	return p
end

local function weldAll(model: Model, root: BasePart)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = descendant
			weld.Parent = descendant
		end
	end
end

local function finish(model: Model, root: BasePart): Model
	model.PrimaryPart = root
	weldAll(model, root)
	return model
end

-- Pet rig ------------------------------------------------------------------------------

type PetLook = {
	bodyColor: Color3,
	accentColor: Color3,
	scale: number,
	ears: boolean?,
	horn: boolean?,
	shell: boolean?,
	longTail: boolean?,
}

-- Builds a quadruped standing with its feet at y = 0 (model space, facing -Z).
function PlaceholderModels.buildPet(speciesId: string, look: PetLook, flying: boolean): Model
	local s = look.scale
	local model = Instance.new("Model")
	model.Name = speciesId

	local legLength = 1.4 * s
	local bodySize = Vector3.new(2.2, 1.7, 3.4) * s
	local bodyY = legLength + bodySize.Y / 2

	local body = part({
		Name = "Body",
		Size = bodySize,
		Color = look.bodyColor,
		CFrame = CFrame.new(0, bodyY, 0),
	})
	body.Parent = model

	local saddle = Instance.new("Attachment")
	saddle.Name = "Saddle"
	saddle.Position = Vector3.new(0, bodySize.Y / 2, 0.15 * s)
	saddle.Parent = body

	local headSize = Vector3.new(1.5, 1.4, 1.5) * s
	local headCFrame = CFrame.new(0, bodyY + bodySize.Y * 0.45, -bodySize.Z / 2 - headSize.Z * 0.3)
	local head = part({ Name = "Head", Size = headSize, Color = look.bodyColor, CFrame = headCFrame })
	head.Parent = model

	local snout = part({
		Name = "Snout",
		Size = Vector3.new(0.8, 0.6, 0.6) * s,
		Color = look.accentColor,
		CFrame = headCFrame * CFrame.new(0, -0.25 * s, -headSize.Z / 2 - 0.2 * s),
	})
	snout.Parent = model

	for _, side in { -1, 1 } do
		local eye = part({
			Name = "Eye",
			Size = Vector3.new(0.22, 0.22, 0.1) * s,
			Color = Color3.fromRGB(20, 20, 28),
			Material = Enum.Material.Neon,
			CFrame = headCFrame * CFrame.new(side * 0.38 * s, 0.2 * s, -headSize.Z / 2 - 0.02),
		})
		eye.Parent = model

		if look.ears then
			local ear = part({
				Name = "Ear",
				ClassName = "WedgePart",
				Size = Vector3.new(0.2, 0.8, 0.5) * s,
				Color = look.accentColor,
				CFrame = headCFrame * CFrame.new(side * 0.45 * s, headSize.Y / 2 + 0.35 * s, 0.1 * s),
			})
			ear.Parent = model
		end
	end

	if look.horn then
		local horn = part({
			Name = "Horn",
			Size = Vector3.new(0.25, 1.0, 0.25) * s,
			Color = look.accentColor,
			Material = Enum.Material.Neon,
			CFrame = headCFrame * CFrame.new(0, headSize.Y / 2 + 0.3 * s, -0.35 * s) * CFrame.Angles(math.rad(-30), 0, 0),
		})
		horn.Parent = model
	end

	if look.shell then
		local shell = part({
			Name = "Shell",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(1, 1, 1) * bodySize.Z * 0.95,
			Color = look.accentColor,
			CFrame = CFrame.new(0, bodyY + bodySize.Y * 0.1, 0.1 * s),
		})
		shell.Parent = model
	end

	local tailLength = if look.longTail then 1.8 * s else 0.7 * s
	local tail = part({
		Name = "Tail",
		Size = Vector3.new(0.4 * s, 0.4 * s, tailLength),
		Color = look.accentColor,
		CFrame = CFrame.new(0, bodyY + bodySize.Y * 0.25, bodySize.Z / 2 + tailLength * 0.4)
			* CFrame.Angles(math.rad(25), 0, 0),
	})
	tail.Parent = model

	for _, x in { -1, 1 } do
		for _, z in { -1, 1 } do
			local leg = part({
				Name = "Leg",
				Size = Vector3.new(0.55 * s, legLength, 0.55 * s),
				Color = look.bodyColor:Lerp(Color3.new(0, 0, 0), 0.15),
				CFrame = CFrame.new(x * bodySize.X * 0.32, legLength / 2, z * bodySize.Z * 0.36),
			})
			leg.Parent = model
		end
	end

	if flying then
		for _, side in { -1, 1 } do
			local wing = part({
				Name = "Wing",
				Size = Vector3.new(3.2 * s, 0.15 * s, 1.8 * s),
				Color = look.accentColor,
				Transparency = 0.1,
				CFrame = CFrame.new(side * (bodySize.X / 2 + 1.4 * s), bodyY + bodySize.Y * 0.35, -0.2 * s)
					* CFrame.Angles(0, 0, side * math.rad(18)),
			})
			wing.Parent = model
		end
	end

	return finish(model, body)
end

-- Eggs -----------------------------------------------------------------------------------

function PlaceholderModels.buildEgg(tierId: string, color: Color3, rarityRank: number): Model
	local model = Instance.new("Model")
	model.Name = tierId .. "Egg"

	local shell = part({
		Name = "Shell",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(3, 3, 3),
		Color = color,
		Material = if rarityRank >= 6 then Enum.Material.Neon else Enum.Material.SmoothPlastic,
		CFrame = CFrame.new(0, 2, 0),
	})
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Scale = Vector3.new(1, 1.3, 1)
	mesh.Parent = shell
	shell.Parent = model

	local spotColor = color:Lerp(Color3.new(1, 1, 1), 0.55)
	for i = 1, 3 do
		local angle = (i / 3) * math.pi * 2
		local spot = part({
			Name = "Spot",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(0.7, 0.7, 0.7),
			Color = spotColor,
			CFrame = CFrame.new(math.cos(angle) * 1.25, 2 + (i - 2) * 0.6, math.sin(angle) * 1.25),
		})
		spot.Parent = model
	end

	if rarityRank >= 3 then
		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = 8 + rarityRank * 2
		light.Brightness = 1 + rarityRank * 0.3
		light.Parent = shell
	end
	if rarityRank >= 4 then
		local sparkles = Instance.new("Sparkles")
		sparkles.SparkleColor = color
		sparkles.Parent = shell
	end

	return finish(model, shell)
end

-- Items ----------------------------------------------------------------------------------

function PlaceholderModels.buildItem(itemId: string, shape: string, color: Color3, hidden: boolean): Model
	local model = Instance.new("Model")
	model.Name = itemId
	local scale = if hidden then 0.8 else 1

	local coreProps: { [string]: any } = {
		Name = "Core",
		Color = color,
		Material = Enum.Material.Neon,
		CFrame = CFrame.new(0, 1.5 * scale, 0),
	}
	if shape == "Pearl" or shape == "Core" or shape == "Apple" or shape == "Nut" then
		coreProps.Shape = Enum.PartType.Ball
		coreProps.Size = Vector3.new(1.3, 1.3, 1.3) * scale
		if shape ~= "Core" then
			coreProps.Material = Enum.Material.SmoothPlastic
		end
	elseif shape == "Feather" then
		coreProps.Size = Vector3.new(0.3, 2.2, 0.7) * scale
		coreProps.CFrame = CFrame.new(0, 1.5 * scale, 0) * CFrame.Angles(0, 0, math.rad(20))
	elseif shape == "Crystal" then
		coreProps.Size = Vector3.new(1, 1, 1) * scale
		coreProps.CFrame = CFrame.new(0, 1.5 * scale, 0) * CFrame.Angles(math.rad(45), 0, math.rad(45))
	elseif shape == "Leaf" then
		coreProps.Shape = Enum.PartType.Cylinder
		coreProps.Size = Vector3.new(0.2, 1.6, 1.6) * scale
		coreProps.Material = Enum.Material.SmoothPlastic
		coreProps.CFrame = CFrame.new(0, 1.5 * scale, 0) * CFrame.Angles(0, 0, math.rad(70))
	else -- Star and anything unknown
		coreProps.Size = Vector3.new(1.4, 1.4, 0.3) * scale
		coreProps.CFrame = CFrame.new(0, 1.5 * scale, 0) * CFrame.Angles(0, 0, math.rad(45))
	end
	local core = part(coreProps)
	core.Parent = model

	if shape == "Star" then
		local arm = part({
			Name = "Arm",
			Size = Vector3.new(1.4, 1.4, 0.3) * scale,
			Color = color,
			Material = Enum.Material.Neon,
			CFrame = CFrame.new(0, 1.5 * scale, 0),
		})
		arm.Parent = model
	elseif shape == "Apple" or shape == "Nut" then
		local stem = part({
			Name = "Stem",
			Size = Vector3.new(0.15, 0.45, 0.15) * scale,
			Color = Color3.fromRGB(90, 60, 30),
			CFrame = CFrame.new(0, 2.3 * scale, 0),
		})
		stem.Parent = model
	elseif shape == "Core" then
		local ring = part({
			Name = "Ring",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.15, 2.1, 2.1) * scale,
			Color = Color3.fromRGB(230, 240, 255),
			Transparency = 0.3,
			CFrame = CFrame.new(0, 1.5 * scale, 0) * CFrame.Angles(0, 0, math.rad(90)),
		})
		ring.Parent = model
	end

	if hidden then
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Transparency = math.max(descendant.Transparency, 0.25)
			end
		end
	end

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = if hidden then 5 else 9
	light.Brightness = if hidden then 0.8 else 1.6
	light.Parent = core

	return finish(model, core)
end

-- Fits a camera to a model inside a ViewportFrame (used by UI previews).
function PlaceholderModels.frameModel(model: Model, camera: Camera, angle: number)
	local cf, size = model:GetBoundingBox()
	local radius = size.Magnitude / 2
	local distance = radius / math.tan(math.rad(camera.FieldOfView / 2)) * 1.05
	local direction = CFrame.Angles(0, angle, 0) * CFrame.Angles(math.rad(15), 0, 0)
	camera.CFrame = CFrame.lookAt(cf.Position + direction:VectorToWorldSpace(Vector3.new(0, 0, -distance)), cf.Position)
end

return PlaceholderModels
