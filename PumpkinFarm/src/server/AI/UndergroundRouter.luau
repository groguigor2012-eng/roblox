--!strict
--[[
	UndergroundRouter
	Path: ServerScriptService.Server.AI.UndergroundRouter

	Real underground navigation for the Zombie Mole. The arena floor is divided into a
	grid (EnemyConfig.ZombieMole.GridCellSize). A cell is diggable when a downward ray
	from above the arena hits a part in Map/Ground whose attribute Diggable is true and
	that is not marked NoDig (rocks = bedrock, the Great Pumpkin foundation and the
	chest pad). Cells outside the arena bounds are invalid. Barricades and fences are
	not in the Ground folder, so tunnels pass beneath outer defenses by design.

	Probing is lazy and cached per arena: each cell is raycast at most once per match.
	Routes are found with A* (8-way, no corner cutting through bedrock, bounded by
	MaxExpansions) and then string-pulled so the mole travels in long straight tunnels.

	The probe is injectable so the algorithm is unit-tested without Roblox geometry
	(tests/specs/router_spec.luau).

	Dependencies: Attributes

	API:
		UndergroundRouter.new(options) -> Router
			options = { MinX, MinZ, MaxX, MaxZ, FloorY, CellSize, MaxExpansions,
			            Probe: (x: number, z: number) -> boolean }
		UndergroundRouter.ForArena(layout, cellSize, maxExpansions) -> Router
		router:IsDiggableAt(position) -> boolean
		router:FindPath(from, to) -> { Vector3 }?        -- floor-level points, excluding `from`
		router:FindNearestDiggable(position, maxCells) -> Vector3?
		router:FindResurfacePoint(target, isFree: (Vector3) -> boolean) -> Vector3?
		router:GetProbeCount() -> number
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Constants.Attributes)

local SQRT2 = math.sqrt(2)
local KEY_STRIDE = 8192

local UndergroundRouter = {}
UndergroundRouter.__index = UndergroundRouter

export type Options = {
	MinX: number,
	MinZ: number,
	MaxX: number,
	MaxZ: number,
	FloorY: number,
	CellSize: number,
	MaxExpansions: number,
	Probe: (x: number, z: number) -> boolean,
}

function UndergroundRouter.new(options: Options)
	local self = setmetatable({}, UndergroundRouter)
	self.MinX = options.MinX
	self.MinZ = options.MinZ
	self.FloorY = options.FloorY
	self.CellSize = options.CellSize
	self.MaxExpansions = options.MaxExpansions
	self.Width = math.max(1, math.floor((options.MaxX - options.MinX) / options.CellSize))
	self.Depth = math.max(1, math.floor((options.MaxZ - options.MinZ) / options.CellSize))
	self._probe = options.Probe
	self._cache = {} :: { [number]: boolean }
	self._probes = 0
	return self
end

function UndergroundRouter.ForArena(layout: any, cellSize: number, maxExpansions: number)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { layout.GroundFolder }
	local top = layout.FloorY + 80
	local probe = function(x: number, z: number): boolean
		local result = Workspace:Raycast(Vector3.new(x, top, z), Vector3.new(0, -160, 0), params)
		if result == nil then
			return false
		end
		local part = result.Instance
		if part:GetAttribute(Attributes.NoDig) then
			return false
		end
		return part:GetAttribute(Attributes.Diggable) == true
	end
	return UndergroundRouter.new({
		MinX = layout.Bounds.MinX,
		MinZ = layout.Bounds.MinZ,
		MaxX = layout.Bounds.MaxX,
		MaxZ = layout.Bounds.MaxZ,
		FloorY = layout.FloorY,
		CellSize = cellSize,
		MaxExpansions = maxExpansions,
		Probe = probe,
	})
end

function UndergroundRouter:GetProbeCount(): number
	return self._probes
end

function UndergroundRouter:_inBounds(cx: number, cz: number): boolean
	return cx >= 0 and cz >= 0 and cx < self.Width and cz < self.Depth
end

function UndergroundRouter:_key(cx: number, cz: number): number
	return cx * KEY_STRIDE + cz
end

function UndergroundRouter:_cellOf(position: Vector3): (number, number)
	return math.floor((position.X - self.MinX) / self.CellSize), math.floor((position.Z - self.MinZ) / self.CellSize)
end

function UndergroundRouter:_cellCenter(cx: number, cz: number): Vector3
	return Vector3.new(self.MinX + (cx + 0.5) * self.CellSize, self.FloorY, self.MinZ + (cz + 0.5) * self.CellSize)
end

function UndergroundRouter:_diggable(cx: number, cz: number): boolean
	if not self:_inBounds(cx, cz) then
		return false
	end
	local key = self:_key(cx, cz)
	local cached = self._cache[key]
	if cached ~= nil then
		return cached
	end
	local center = self:_cellCenter(cx, cz)
	self._probes += 1
	local value = self._probe(center.X, center.Z)
	self._cache[key] = value
	return value
end

function UndergroundRouter:IsDiggableAt(position: Vector3): boolean
	local cx, cz = self:_cellOf(position)
	return self:_diggable(cx, cz)
end

function UndergroundRouter:_nearestDiggableCell(cx: number, cz: number, maxCells: number): (number?, number?)
	if self:_diggable(cx, cz) then
		return cx, cz
	end
	for radius = 1, maxCells do
		local best, bestX, bestZ = math.huge, nil, nil
		for dx = -radius, radius do
			for dz = -radius, radius do
				if math.max(math.abs(dx), math.abs(dz)) == radius and self:_diggable(cx + dx, cz + dz) then
					local d = dx * dx + dz * dz
					if d < best then
						best, bestX, bestZ = d, cx + dx, cz + dz
					end
				end
			end
		end
		if bestX then
			return bestX, bestZ
		end
	end
	return nil, nil
end

function UndergroundRouter:FindNearestDiggable(position: Vector3, maxCells: number): Vector3?
	local cx, cz = self:_cellOf(position)
	local nx, nz = self:_nearestDiggableCell(cx, cz, maxCells)
	if nx == nil or nz == nil then
		return nil
	end
	return self:_cellCenter(nx, nz)
end

-- Binary min-heap on f-score -----------------------------------------------------------

local function heapPush(keys: { number }, scores: { number }, key: number, score: number)
	table.insert(keys, key)
	table.insert(scores, score)
	local i = #keys
	while i > 1 do
		local parent = i // 2
		if scores[parent] <= scores[i] then
			break
		end
		keys[parent], keys[i] = keys[i], keys[parent]
		scores[parent], scores[i] = scores[i], scores[parent]
		i = parent
	end
end

local function heapPop(keys: { number }, scores: { number }): number
	local top = keys[1]
	local last = #keys
	keys[1], scores[1] = keys[last], scores[last]
	keys[last], scores[last] = nil, nil
	local n = last - 1
	local i = 1
	while true do
		local left, right = i * 2, i * 2 + 1
		local smallest = i
		if left <= n and scores[left] < scores[smallest] then
			smallest = left
		end
		if right <= n and scores[right] < scores[smallest] then
			smallest = right
		end
		if smallest == i then
			break
		end
		keys[smallest], keys[i] = keys[i], keys[smallest]
		scores[smallest], scores[i] = scores[i], scores[smallest]
		i = smallest
	end
	return top
end

local NEIGHBOURS = {
	{ 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 },
	{ 1, 1, SQRT2 }, { 1, -1, SQRT2 }, { -1, 1, SQRT2 }, { -1, -1, SQRT2 },
}

local function octile(ax: number, az: number, bx: number, bz: number): number
	local dx, dz = math.abs(ax - bx), math.abs(az - bz)
	return math.max(dx, dz) + (SQRT2 - 1) * math.min(dx, dz)
end

-- True when a tunnel of almost one cell width along the segment stays on diggable
-- cells. The width matters: a zero-width line could slip diagonally through the
-- corner between two bedrock cells, which A* itself forbids.
function UndergroundRouter:_lineDiggable(a: Vector3, b: Vector3): boolean
	local delta = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local length = delta.Magnitude
	if length < 1e-3 then
		local cx, cz = self:_cellOf(a)
		return self:_diggable(cx, cz)
	end
	local side = Vector3.new(-delta.Z, 0, delta.X) / length * (self.CellSize * 0.45)
	local steps = math.max(1, math.ceil(length / (self.CellSize * 0.25)))
	for i = 0, steps do
		local p = a + delta * (i / steps)
		for _, offset in { Vector3.zero, side, -side } do
			local cx, cz = self:_cellOf(p + offset)
			if not self:_diggable(cx, cz) then
				return false
			end
		end
	end
	return true
end

function UndergroundRouter:_smooth(points: { Vector3 }): { Vector3 }
	if #points <= 2 then
		return points
	end
	local result = { points[1] }
	local anchor = 1
	while anchor < #points do
		local furthest = anchor + 1
		for candidate = #points, anchor + 2, -1 do
			if self:_lineDiggable(points[anchor], points[candidate]) then
				furthest = candidate
				break
			end
		end
		table.insert(result, points[furthest])
		anchor = furthest
	end
	return result
end

function UndergroundRouter:FindPath(from: Vector3, to: Vector3): { Vector3 }?
	local fx, fz = self:_cellOf(from)
	local tx, tz = self:_cellOf(to)
	local sx, sz = self:_nearestDiggableCell(fx, fz, 3)
	local gx, gz = self:_nearestDiggableCell(tx, tz, 3)
	if sx == nil or sz == nil or gx == nil or gz == nil then
		return nil
	end

	local startKey = self:_key(sx, sz)
	local goalKey = self:_key(gx, gz)
	local gScore: { [number]: number } = { [startKey] = 0 }
	local cameFrom: { [number]: number } = {}
	local closed: { [number]: boolean } = {}
	local heapKeys, heapScores = {}, {}
	heapPush(heapKeys, heapScores, startKey, octile(sx, sz, gx, gz))

	local expansions = 0
	local found = false
	while #heapKeys > 0 do
		local current = heapPop(heapKeys, heapScores)
		if current == goalKey then
			found = true
			break
		end
		if not closed[current] then
			closed[current] = true
			expansions += 1
			if expansions > self.MaxExpansions then
				break
			end
			local cx, cz = current // KEY_STRIDE, current % KEY_STRIDE
			for _, offset in NEIGHBOURS do
				local nx, nz = cx + offset[1], cz + offset[2]
				local diagonal = offset[1] ~= 0 and offset[2] ~= 0
				local passable = self:_diggable(nx, nz)
				if passable and diagonal then
					-- No squeezing diagonally between two bedrock cells.
					passable = self:_diggable(cx + offset[1], cz) and self:_diggable(cx, cz + offset[2])
				end
				if passable then
					local neighbourKey = self:_key(nx, nz)
					if not closed[neighbourKey] then
						local tentative = gScore[current] + offset[3]
						local known = gScore[neighbourKey]
						if known == nil or tentative < known then
							gScore[neighbourKey] = tentative
							cameFrom[neighbourKey] = current
							heapPush(heapKeys, heapScores, neighbourKey, tentative + octile(nx, nz, gx, gz))
						end
					end
				end
			end
		end
	end
	if not found then
		return nil
	end

	local cells = {}
	local key: number? = goalKey
	while key ~= nil do
		table.insert(cells, 1, self:_cellCenter(key // KEY_STRIDE, key % KEY_STRIDE))
		key = cameFrom[key]
	end
	local smoothed = self:_smooth(cells)
	table.remove(smoothed, 1) -- the start cell is where the mole already is
	return smoothed
end

function UndergroundRouter:FindResurfacePoint(target: Vector3, isFree: (Vector3) -> boolean): Vector3?
	for _, radius in { 3.5, 5.5, 7.5 } do
		for step = 0, 7 do
			local angle = step / 8 * math.pi * 2
			local candidate = Vector3.new(target.X + math.cos(angle) * radius, self.FloorY, target.Z + math.sin(angle) * radius)
			if self:IsDiggableAt(candidate) and isFree(candidate) then
				return candidate
			end
		end
	end
	if self:IsDiggableAt(target) then
		return Vector3.new(target.X, self.FloorY, target.Z)
	end
	return nil
end

return UndergroundRouter
