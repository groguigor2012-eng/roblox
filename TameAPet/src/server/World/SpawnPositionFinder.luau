-- Finds valid ground positions inside a (possibly rotated) zone part:
--   1. pick a random point in the zone's local X/Z extents (so rotation is respected)
--   2. raycast straight down from the zone's top against map geometry only
--   3. reject: no hit, too steep, outside the zone box, surfaces tagged NoSpawn,
--      anything overhead (inside a wall / under an overhang / under terrain),
--      obstacles occupying the spawn footprint, or too close to an existing object.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZoneConfig = require(ReplicatedStorage.Config.ZoneConfig)

local SpawnPositionFinder = {}

local function mapGeometry(): { Instance }
	local list: { Instance } = { workspace.Terrain }
	local map = workspace:FindFirstChild("Map")
	if map then
		table.insert(list, map)
	end
	return list
end

local function isTooClose(position: Vector3, occupied: { Vector3 }, minSpacing: number): boolean
	for _, other in occupied do
		if (other - position).Magnitude < minSpacing then
			return true
		end
	end
	return false
end

export type Options = {
	occupied: { Vector3 },
	minSpacing: number,
	rng: Random,
	attempts: number?,
}

function SpawnPositionFinder.find(zonePart: BasePart, options: Options): Vector3?
	local placement = ZoneConfig.Placement
	local geometry = mapGeometry()

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.FilterDescendantsInstances = geometry
	rayParams.IgnoreWater = false

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = geometry

	local half = zonePart.Size / 2
	local minNormalY = math.cos(math.rad(placement.maxSlopeDegrees))
	local clearance = placement.clearanceHeight
	local footprint = placement.footprint

	for _ = 1, options.attempts or placement.attempts do
		local localX = options.rng:NextNumber(-half.X, half.X)
		local localZ = options.rng:NextNumber(-half.Z, half.Z)
		local top = zonePart.CFrame:PointToWorldSpace(Vector3.new(localX, half.Y, localZ))
		local result = workspace:Raycast(top, Vector3.new(0, -(zonePart.Size.Y + 20), 0), rayParams)
		if not result then
			continue
		end
		if result.Normal.Y < minNormalY then
			continue
		end
		if result.Instance:GetAttribute("NoSpawn") then
			continue
		end
		if result.Material == Enum.Material.Water then
			continue
		end
		local position = result.Position
		local localPoint = zonePart.CFrame:PointToObjectSpace(position)
		if math.abs(localPoint.X) > half.X or math.abs(localPoint.Y) > half.Y or math.abs(localPoint.Z) > half.Z then
			continue
		end
		-- Nothing may be overhead between the spawn point and the top of the zone.
		local upStart = position + Vector3.new(0, 0.2, 0)
		if workspace:Raycast(upStart, Vector3.new(0, top.Y - upStart.Y, 0), rayParams) then
			continue
		end
		-- The footprint above the ground must be free of obstacles.
		local boxCenter = CFrame.new(position + Vector3.new(0, clearance / 2 + 0.5, 0))
		if #workspace:GetPartBoundsInBox(boxCenter, Vector3.new(footprint, clearance, footprint), overlapParams) > 0 then
			continue
		end
		if isTooClose(position, options.occupied, options.minSpacing) then
			continue
		end
		return position
	end
	return nil
end

return SpawnPositionFinder
