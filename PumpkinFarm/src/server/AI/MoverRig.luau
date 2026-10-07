--!strict
--[[
	MoverRig
	Path: ServerScriptService.Server.AI.MoverRig

	Constraint-based mover for enemies that must not walk: flying Plague Crows and
	tunnelling Zombie Moles. AlignPosition/AlignOrientation (OneAttachment mode) pull
	the root toward a target, counteract gravity, cap speed with MaxVelocity, and give
	smooth physics replication to clients (the server owns the assembly).

	Dependencies: none

	API:
		MoverRig.new(root) -> MoverRig
		rig:SetTarget(position, lookAt?)
		rig:SetMaxSpeed(studsPerSecond)
		rig:SetEnabled(enabled)
		rig:Destroy()
]]

local MoverRig = {}
MoverRig.__index = MoverRig

function MoverRig.new(root: BasePart)
	local attachment = Instance.new("Attachment")
	attachment.Name = "MoverAttachment"
	attachment.Parent = root

	local align = Instance.new("AlignPosition")
	align.Name = "MoverPosition"
	align.Mode = Enum.PositionAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.MaxForce = math.huge
	align.MaxVelocity = 20
	align.Responsiveness = 30
	align.Position = root.Position
	align.Enabled = false
	align.Parent = root

	local orient = Instance.new("AlignOrientation")
	orient.Name = "MoverOrientation"
	orient.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orient.Attachment0 = attachment
	orient.MaxTorque = math.huge
	orient.Responsiveness = 20
	orient.CFrame = root.CFrame.Rotation
	orient.Enabled = false
	orient.Parent = root

	return setmetatable({
		Root = root,
		_attachment = attachment,
		_align = align,
		_orient = orient,
	}, MoverRig)
end

function MoverRig:SetTarget(position: Vector3, lookAt: Vector3?)
	self._align.Position = position
	local facing = lookAt or position
	local flat = Vector3.new(facing.X - self.Root.Position.X, 0, facing.Z - self.Root.Position.Z)
	if flat.Magnitude > 0.1 then
		self._orient.CFrame = CFrame.lookAt(Vector3.zero, flat)
	end
end

function MoverRig:SetMaxSpeed(speed: number)
	self._align.MaxVelocity = math.max(0, speed)
end

function MoverRig:SetEnabled(enabled: boolean)
	self._align.Enabled = enabled
	self._orient.Enabled = enabled
end

function MoverRig:Destroy()
	self._align:Destroy()
	self._orient:Destroy()
	self._attachment:Destroy()
end

return MoverRig
