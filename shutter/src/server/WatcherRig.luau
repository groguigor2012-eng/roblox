--!strict
-- Builds the default WATCHER: a tall, gaunt silhouette with a pale, featureless head and two
-- pin-prick eyes. Used when the place has no model tagged ShutterEntity. Swap in your own
-- model any time: tag it ShutterEntity, give it a PrimaryPart, and WatcherService drives it.
--
-- Every part is Anchored / CanCollide=false: the server moves the whole model with PivotTo,
-- so there is no physics owner to exploit and "frozen" means exactly frozen.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shutter"):WaitForChild("Config"))

local WatcherRig = {}

local BODY_COLOR = Color3.fromRGB(14, 14, 17)
local SKIN_COLOR = Color3.fromRGB(214, 208, 196)
local EYE_COLOR = Color3.fromRGB(255, 250, 240)

WatcherRig.HEIGHT = 9 -- studs, feet to crown
WatcherRig.HIP_HEIGHT = 4.5 -- pivot (Root centre) above the feet

local function makePart(model: Model, name: string, size: Vector3, offset: CFrame, color: Color3, material: Enum.Material): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = offset
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = true
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	return part
end

-- Builds the rig with its feet at `feetPosition`, facing `facing` (defaults to -Z).
function WatcherRig.build(feetPosition: Vector3, facing: Vector3?): Model
	local model = Instance.new("Model")
	model.Name = "TheWatcher"

	local look = facing or Vector3.new(0, 0, -1)
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, -1)
	end
	local origin = feetPosition + Vector3.new(0, WatcherRig.HIP_HEIGHT, 0)
	local rootCFrame = CFrame.lookAt(origin, origin + flat.Unit)
	local function at(x: number, y: number, z: number): CFrame
		return rootCFrame * CFrame.new(x, y, z)
	end

	local root = makePart(model, "Root", Vector3.new(2, WatcherRig.HEIGHT, 1.2), rootCFrame, BODY_COLOR, Enum.Material.SmoothPlastic)
	root.Transparency = 1

	-- Legs: ground (-4.5) to hips (-0.3)
	makePart(model, "LeftLeg", Vector3.new(0.45, 4.2, 0.45), at(-0.45, -2.4, 0), BODY_COLOR, Enum.Material.SmoothPlastic)
	makePart(model, "RightLeg", Vector3.new(0.45, 4.2, 0.45), at(0.45, -2.4, 0), BODY_COLOR, Enum.Material.SmoothPlastic)
	-- Torso: hips to shoulders (2.5)
	makePart(model, "Torso", Vector3.new(1.5, 2.8, 0.6), at(0, 1.1, 0), BODY_COLOR, Enum.Material.SmoothPlastic)
	-- Arms hang far too low, slightly splayed.
	makePart(model, "LeftArm", Vector3.new(0.32, 4.8, 0.32), at(-1.05, 0.05, 0) * CFrame.Angles(0, 0, math.rad(-4)), BODY_COLOR, Enum.Material.SmoothPlastic)
	makePart(model, "RightArm", Vector3.new(0.32, 4.8, 0.32), at(1.05, 0.05, 0) * CFrame.Angles(0, 0, math.rad(4)), BODY_COLOR, Enum.Material.SmoothPlastic)
	makePart(model, "Neck", Vector3.new(0.3, 0.7, 0.3), at(0, 2.8, 0), BODY_COLOR, Enum.Material.SmoothPlastic)
	-- Head tilted a few degrees, as if listening.
	local head = makePart(model, "Head", Vector3.new(1.1, 1.5, 1.1), at(0, 3.7, 0) * CFrame.Angles(0, 0, math.rad(9)), SKIN_COLOR, Enum.Material.SmoothPlastic)
	local headMesh = Instance.new("SpecialMesh")
	headMesh.MeshType = Enum.MeshType.Sphere
	headMesh.Parent = head
	makePart(model, "LeftEye", Vector3.new(0.16, 0.1, 0.05), head.CFrame * CFrame.new(-0.22, 0.1, -0.53), EYE_COLOR, Enum.Material.Neon)
	makePart(model, "RightEye", Vector3.new(0.16, 0.1, 0.05), head.CFrame * CFrame.new(0.22, 0.1, -0.53), EYE_COLOR, Enum.Material.Neon)

	model.PrimaryPart = root
	CollectionService:AddTag(model, Config.Tags.CameraOnly)
	CollectionService:AddTag(model, Config.Tags.Entity)
	return model
end

return WatcherRig
