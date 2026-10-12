-- Builds a rideable mount rig around any pet model:
--   Root      invisible Ball collider (slides over slopes and small ledges, kept upright by
--             AlignOrientation), the assembly root and network-ownership anchor
--   Visual    the pet model (ServerStorage.MountModels / PetModels or a placeholder),
--             welded to Root, massless and non-colliding
--   Seat      rider seat at the model's "Saddle" attachment (or the top of the model)
--   Constraints: LinearVelocity + AlignOrientation on Root.MountAttachment

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MountConfig = require(ReplicatedStorage.Config.MountConfig)
local AssetLibrary = require(script.Parent.AssetLibrary)

local MountFactory = {}

export type MountRig = {
	model: Model,
	root: BasePart,
	seat: Seat,
	attachment: Attachment,
	linearVelocity: LinearVelocity,
	alignOrientation: AlignOrientation,
	radius: number,
}

-- groundCFrame: position on the ground where the mount's feet should rest, with the desired
-- facing. Returns nil if no model is available for the species.
function MountFactory.build(speciesId: string, groundCFrame: CFrame): MountRig?
	local visual = AssetLibrary.pet(speciesId, true)
	if not visual then
		return nil
	end

	local boxCFrame, boxSize = visual:GetBoundingBox()
	local diameter = math.clamp(math.min(boxSize.X, boxSize.Z) * 0.9, 2.5, 8)
	local radius = diameter / 2

	local model = Instance.new("Model")
	model.Name = "Mount_" .. speciesId

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Shape = Enum.PartType.Ball
	root.Size = Vector3.new(diameter, diameter, diameter)
	root.Transparency = 1
	root.CanCollide = true
	root.CanTouch = false
	root.CanQuery = false
	root.Anchored = false
	root.RootPriority = 100
	root.CustomPhysicalProperties = PhysicalProperties.new(1, 0, 0, 100, 100)
	local rotation = groundCFrame - groundCFrame.Position
	root.CFrame = CFrame.new(groundCFrame.Position + Vector3.new(0, radius + 0.1, 0)) * rotation
	root.Parent = model

	-- Place the visual so the bottom of its bounding box sits at the bottom of the collider.
	local boxRelativeToPivot = visual:GetPivot():ToObjectSpace(boxCFrame)
	local targetBox = root.CFrame * CFrame.new(0, -radius + boxSize.Y / 2, 0)
	visual:PivotTo(targetBox * boxRelativeToPivot:Inverse())
	for _, descendant in visual:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
		end
	end
	local visualRoot = visual.PrimaryPart :: BasePart
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = visualRoot
	weld.Parent = root
	visual.Name = "Visual"
	visual.Parent = model

	local saddle = visual:FindFirstChild("Saddle", true)
	local seatPosition
	if saddle and saddle:IsA("Attachment") then
		seatPosition = saddle.WorldPosition
	else
		local newBox, newSize = visual:GetBoundingBox()
		seatPosition = newBox.Position + Vector3.new(0, newSize.Y / 2, 0)
	end
	local seat = Instance.new("Seat")
	seat.Name = "Seat"
	seat.Size = Vector3.new(2, 0.4, 2)
	seat.Transparency = 1
	seat.CanCollide = false
	seat.CanTouch = false -- only MountService can seat a rider (Seat:Sit), never touch
	seat.CanQuery = false
	seat.Massless = true
	seat.Anchored = false
	seat.CFrame = CFrame.new(seatPosition + Vector3.new(0, 0.2, 0)) * rotation
	local seatWeld = Instance.new("WeldConstraint")
	seatWeld.Part0 = root
	seatWeld.Part1 = seat
	seatWeld.Parent = seat
	seat.Parent = model

	local attachment = Instance.new("Attachment")
	attachment.Name = "MountAttachment"
	attachment.Parent = root

	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "MoveVelocity"
	linearVelocity.Attachment0 = attachment
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	linearVelocity.PrimaryTangentAxis = Vector3.xAxis
	linearVelocity.SecondaryTangentAxis = Vector3.zAxis
	linearVelocity.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	linearVelocity.MaxForce = MountConfig.MaxForce
	linearVelocity.PlaneVelocity = Vector2.zero
	linearVelocity.Parent = root

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "KeepUpright"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.MaxTorque = MountConfig.MaxTorque
	alignOrientation.Responsiveness = MountConfig.OrientationResponsiveness
	alignOrientation.CFrame = rotation
	alignOrientation.Parent = root

	model.PrimaryPart = root
	return {
		model = model,
		root = root,
		seat = seat,
		attachment = attachment,
		linearVelocity = linearVelocity,
		alignOrientation = alignOrientation,
		radius = radius,
	}
end

return MountFactory
