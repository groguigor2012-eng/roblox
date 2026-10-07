--[[
	Spatial queries for the server simulation: Workspace:Raycast / Spherecast /
	GetPartBoundsInBox, movement collision and ground probing, over the emulated
	Instance tree.

	Parts are treated as oriented boxes (balls and cylinders use their box). Static map
	geometry (any folder named "Map" or "Lobby", and their subfolders) is indexed once in
	a 16-stud XZ grid; everything else is gathered per query (it is small: defenses,
	farm objects, characters, enemies).

	Raycast rules mirror the engine closely enough for gameplay code:
	  * CanQuery = false parts are ignored
	  * parts in the Ghost collision group are ignored (Ghost does not collide with
	    Default, which is the group raycasts use)
]]

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local CELL = 16
local GHOST = "PF_Ghost"

local Geometry = {}
Geometry.__index = Geometry

local function aabbOf(part)
	local cf, size = part.CFrame, part.Size
	local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
	local half = Vector3.new(
		math.abs(r.X) * size.X + math.abs(u.X) * size.Y + math.abs(l.X) * size.Z,
		math.abs(r.Y) * size.X + math.abs(u.Y) * size.Y + math.abs(l.Y) * size.Z,
		math.abs(r.Z) * size.X + math.abs(u.Z) * size.Y + math.abs(l.Z) * size.Z
	) / 2
	local c = cf.Position
	return c - half, c + half
end

function Geometry.new(workspace)
	local self = setmetatable({}, Geometry)
	self.Workspace = workspace
	self._grids = setmetatable({}, { __mode = "k" })
	return self
end

local function isStaticRoot(instance): boolean
	local current = instance
	while current do
		local name = current.Name
		if (name == "Map" or name == "Lobby") and current:IsA("Folder") then
			return true
		end
		current = current.Parent
	end
	return false
end
Geometry.IsStatic = isStaticRoot

function Geometry:_grid(root)
	local grid = self._grids[root]
	if grid then
		return grid
	end
	grid = { Cells = {}, Parts = {} }
	for _, part in root:GetDescendants() do
		if part:IsA("BasePart") then
			local min, max = aabbOf(part)
			local entry = { Part = part, Min = min, Max = max }
			table.insert(grid.Parts, entry)
			for cx = math.floor(min.X / CELL), math.floor(max.X / CELL) do
				for cz = math.floor(min.Z / CELL), math.floor(max.Z / CELL) do
					local key = cx * 100000 + cz
					local cell = grid.Cells[key]
					if cell == nil then
						cell = {}
						grid.Cells[key] = cell
					end
					table.insert(cell, entry)
				end
			end
		end
	end
	self._grids[root] = grid
	return grid
end

-- Entries (part + AABB) from a static grid overlapping the XZ rectangle.
local function gridQuery(grid, minX: number, minZ: number, maxX: number, maxZ: number, out, seen)
	for cx = math.floor(minX / CELL), math.floor(maxX / CELL) do
		for cz = math.floor(minZ / CELL), math.floor(maxZ / CELL) do
			local cell = grid.Cells[cx * 100000 + cz]
			if cell then
				for _, entry in cell do
					if not seen[entry] then
						seen[entry] = true
						table.insert(out, entry)
					end
				end
			end
		end
	end
end

local function dynamicEntries(root, out, excluded)
	if excluded[root] then
		return
	end
	if root:IsA("BasePart") then
		local min, max = aabbOf(root)
		table.insert(out, { Part = root, Min = min, Max = max })
	end
	for _, child in root:GetChildren() do
		dynamicEntries(child, out, excluded)
	end
end

-- Candidate entries for a query region, honouring Include/Exclude filters.
function Geometry:_candidates(params, minX: number, minZ: number, maxX: number, maxZ: number)
	local out, seen = {}, {}
	local include = params and params.FilterType ~= nil and params.FilterType.Name == "Include"
	local list = (params and params.FilterDescendantsInstances) or {}
	if include then
		for _, root in list do
			if root ~= nil then
				if isStaticRoot(root) then
					gridQuery(self:_grid(root), minX, minZ, maxX, maxZ, out, seen)
				else
					dynamicEntries(root, out, {})
				end
			end
		end
		return out
	end
	local excluded = {}
	for _, instance in list do
		if instance ~= nil then
			excluded[instance] = true
		end
	end
	local function walk(node)
		if excluded[node] then
			return
		end
		if (node.Name == "Map" or node.Name == "Lobby") and node:IsA("Folder") then
			gridQuery(self:_grid(node), minX, minZ, maxX, maxZ, out, seen)
			return
		end
		if node:IsA("BasePart") then
			local min, max = aabbOf(node)
			table.insert(out, { Part = node, Min = min, Max = max })
		end
		for _, child in node:GetChildren() do
			walk(child)
		end
	end
	for _, child in self.Workspace:GetChildren() do
		walk(child)
	end
	-- Excluded descendants of static roots still need removing.
	if next(excluded) then
		local filtered = {}
		for _, entry in out do
			local blocked = false
			for instance in excluded do
				if entry.Part == instance or entry.Part:IsDescendantOf(instance) then
					blocked = true
					break
				end
			end
			if not blocked then
				table.insert(filtered, entry)
			end
		end
		out = filtered
	end
	return out
end

-- Ray vs oriented box (slab test in the part's local space). Returns distance or nil.
local function rayBox(part, origin, direction)
	local cf, half = part.CFrame, part.Size / 2
	local localOrigin = cf:PointToObjectSpace(origin)
	local localDirection = cf:VectorToObjectSpace(direction)
	local tMin, tMax = 0, 1
	local normalAxis, normalSign = 0, 0
	for axis = 1, 3 do
		local o = if axis == 1 then localOrigin.X elseif axis == 2 then localOrigin.Y else localOrigin.Z
		local d = if axis == 1 then localDirection.X elseif axis == 2 then localDirection.Y else localDirection.Z
		local h = if axis == 1 then half.X elseif axis == 2 then half.Y else half.Z
		if math.abs(d) < 1e-9 then
			if o < -h or o > h then
				return nil
			end
		else
			local t1, t2 = (-h - o) / d, (h - o) / d
			local sign = -1
			if t1 > t2 then
				t1, t2 = t2, t1
				sign = 1
			end
			if t1 > tMin then
				tMin = t1
				normalAxis, normalSign = axis, sign
			end
			tMax = math.min(tMax, t2)
			if tMin > tMax then
				return nil
			end
		end
	end
	local localNormal = Vector3.new(
		if normalAxis == 1 then normalSign else 0,
		if normalAxis == 2 then normalSign else 0,
		if normalAxis == 3 then normalSign else 0
	)
	return tMin, cf:VectorToWorldSpace(localNormal)
end

function Geometry:Raycast(origin, direction, params)
	local finish = origin + direction
	local minX, maxX = math.min(origin.X, finish.X), math.max(origin.X, finish.X)
	local minZ, maxZ = math.min(origin.Z, finish.Z), math.max(origin.Z, finish.Z)
	local best, bestT, bestNormal = nil, math.huge, nil
	for _, entry in self:_candidates(params, minX, minZ, maxX, maxZ) do
		local part = entry.Part
		if part.Parent ~= nil and part.CanQuery and part.CollisionGroup ~= GHOST then
			local t, normal = rayBox(part, origin, direction)
			if t and t < bestT then
				best, bestT, bestNormal = part, t, normal
			end
		end
	end
	if best == nil then
		return nil
	end
	return {
		Instance = best,
		Position = origin + direction * bestT,
		Normal = bestNormal,
		Distance = direction.Magnitude * bestT,
		Material = best.Material,
	}
end

function Geometry:GetPartBoundsInBox(cframe, size, params)
	local qMin, qMax = aabbOf({ CFrame = cframe, Size = size })
	local results = {}
	for _, entry in self:_candidates(params, qMin.X, qMin.Z, qMax.X, qMax.Z) do
		local part = entry.Part
		if part.Parent ~= nil and part.CanQuery and part.CollisionGroup ~= GHOST then
			local min, max = entry.Min, entry.Max
			if min.X < qMax.X and max.X > qMin.X and min.Y < qMax.Y and max.Y > qMin.Y and min.Z < qMax.Z and max.Z > qMin.Z then
				table.insert(results, part)
			end
		end
	end
	return results
end

-- Collision groups that block a mover (mirrors Server.Systems.CollisionGroups). Players
-- and enemies never block each other here, to keep crowds moving.
local BLOCKS = {
	PF_Players = { Default = true },
	PF_Enemies = { Default = true, PF_Defenses = true },
}

-- Is a straight move from `from` to `to` blocked by a solid part at body height?
-- Only the arena's static map and its Defenses folder can block (creatures never
-- block each other in the simulation), which keeps this cheap enough to run for every
-- walker every frame.
function Geometry:MoveBlocked(map, defenses, from, to, moverGroup: string, radius: number): boolean
	local blockers = BLOCKS[moverGroup]
	if blockers == nil or map == nil then
		return false
	end
	local delta = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local length = delta.Magnitude
	if length < 1e-4 then
		return false
	end
	local probe = delta.Unit * (length + radius)
	local params = { FilterType = { Name = "Include" }, FilterDescendantsInstances = { map, defenses } }
	for _, entry in self:_candidates(params, math.min(from.X, from.X + probe.X) - 1, math.min(from.Z, from.Z + probe.Z) - 1, math.max(from.X, from.X + probe.X) + 1, math.max(from.Z, from.Z + probe.Z) + 1) do
		local part = entry.Part
		local group = part.CollisionGroup
		if part.Parent ~= nil and part.CanCollide and blockers[group] and entry.Max.Y > from.Y - 1 and entry.Min.Y < from.Y + 2 then
			if rayBox(part, from, probe) then
				return true
			end
		end
	end
	return false
end

-- Top surface of walkable static ground under a point, or nil.
function Geometry:GroundHeight(position, mapRoot)
	local params = { FilterType = { Name = "Include" }, FilterDescendantsInstances = { mapRoot } }
	local hit = self:Raycast(position + Vector3.new(0, 40, 0), Vector3.new(0, -120, 0), params)
	return hit and hit.Position.Y
end

-- True when no tall static obstacle (above `floorY + 1.2`) overlaps the XZ cell.
function Geometry:CellWalkable(mapRoot, x: number, z: number, halfSize: number, floorY: number): boolean
	local out, seen = {}, {}
	gridQuery(self:_grid(mapRoot), x - halfSize, z - halfSize, x + halfSize, z + halfSize, out, seen)
	for _, entry in out do
		local part = entry.Part
		if part.CanCollide and entry.Max.Y > floorY + 1.2 and entry.Min.Y < floorY + 6 then
			local min, max = entry.Min, entry.Max
			if min.X < x + halfSize and max.X > x - halfSize and min.Z < z + halfSize and max.Z > z - halfSize then
				-- Thin rotated parts (fence segments) have loose AABBs; confirm with a ray
				-- through the cell centre along both axes before declaring it blocked.
				local y = floorY + 3
				local hitX = rayBox(part, Vector3.new(x - halfSize, y, z), Vector3.new(halfSize * 2, 0, 0))
				local hitZ = rayBox(part, Vector3.new(x, y, z - halfSize), Vector3.new(0, 0, halfSize * 2))
				if hitX or hitZ then
					return false
				end
			end
		end
	end
	return true
end

return Geometry
