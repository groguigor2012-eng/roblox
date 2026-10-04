--!strict
-- Chunk layouts. A chunk is a CHUNK_SIZE x CHUNK_SIZE cell of the grid.
--
-- Each layout fills the chunk's INTERIOR only (it stays EDGE_MARGIN studs away from
-- the borders). Walls, archways and corner piers on the borders belong to Joints,
-- which are shared between neighbouring chunks, so two chunks can never disagree
-- about the wall between them and no geometry is ever doubled up.
--
-- Local space for every layout: origin at the chunk center, y = 0 at the floor top.

local Config = require(script.Parent.Config)
local Builders = require(script.Parent.Builders)

type Rect = Builders.Rect

export type WaterRegion = { rect: Rect, y0: number, y1: number }

export type Context = {
	i: number,
	j: number,
	model: Model,
	frame: CFrame,
	rng: Random,
	half: number,
	height: number, -- floor to ceiling
	water: number, -- floor to water surface
	deep: number, -- local y of deep pool floors
	floorHoles: { Rect },
	ceilingHoles: { Rect },
	water_regions: { WaterRegion },
}

local Chunks = {}

local POOL: Builders.Props = { color = Config.POOL_TILE_COLOR }
local QUARTER = math.pi / 2

-- Helpers ------------------------------------------------------------------------

-- Rect in the x/z plane (y0/y1 hold Z).
local function rect(x0: number, z0: number, x1: number, z1: number): Rect
	return { x0 = x0, x1 = x1, y0 = z0, y1 = z1 }
end
Chunks.rect = rect

-- Rotate an x/z rect by a multiple of 90 degrees around the chunk center.
local function rotateRect(r: Rect, angle: number): Rect
	local rot = CFrame.Angles(0, angle, 0)
	local a = rot * Vector3.new(r.x0, 0, r.y0)
	local b = rot * Vector3.new(r.x1, 0, r.y1)
	local function snap(v: number): number
		return math.round(v * 1000) / 1000
	end
	return rect(snap(math.min(a.X, b.X)), snap(math.min(a.Z, b.Z)), snap(math.max(a.X, b.X)), snap(math.max(a.Z, b.Z)))
end

local function randomQuarter(ctx: Context): number
	return ctx.rng:NextInteger(0, 3) * QUARTER
end

-- Ceiling opening with a glowing shaft above it.
local function addLightWell(ctx: Context, x: number, z: number, size: number, depth: number)
	local h = size / 2
	table.insert(ctx.ceilingHoles, rect(x - h, z - h, x + h, z + h))
	Builders.lightWell(ctx.model, ctx.frame * CFrame.new(x, ctx.height, z), size, depth)
end

export type PitOptions = {
	rot: number?, -- rotation (multiple of 90 degrees) of the rect around the chunk center
	steps: boolean?, -- add pool steps along the rect's -Z side
	skip: { [string]: boolean }?, -- side walls to omit: x0 / x1 / z0 / z1
}

-- Sunken pool: cuts the floor, builds the basin walls/floor in aqua tile and
-- registers the water volume. `r` and `bottom` are in (rotated) local space.
local function addPit(ctx: Context, r: Rect, bottom: number, opts: PitOptions?)
	local rot = (opts and opts.rot) or 0
	local skip: { [string]: boolean } = (opts and opts.skip) or {}
	local f = ctx.frame * CFrame.Angles(0, rot, 0)
	local world = rotateRect(r, rot)
	table.insert(ctx.floorHoles, world)
	table.insert(ctx.water_regions, { rect = world, y0 = bottom, y1 = ctx.water - 4 })

	local t = 1
	local top = -Config.FLOOR_THICKNESS -- the floor slab's hole edge covers the last stud
	-- Basin floor (it only extends under the side walls that are actually built).
	local function lip(side: string): number
		return if skip[side] then 0 else t
	end
	Builders.box(
		ctx.model,
		f,
		Vector3.new(r.x0 - lip("x0"), bottom - t, r.y0 - lip("z0")),
		Vector3.new(r.x1 + lip("x1"), bottom, r.y1 + lip("z1")),
		POOL
	)
	if not skip.x0 then
		Builders.box(ctx.model, f, Vector3.new(r.x0 - t, bottom, r.y0), Vector3.new(r.x0, top, r.y1), POOL)
	end
	if not skip.x1 then
		Builders.box(ctx.model, f, Vector3.new(r.x1, bottom, r.y0), Vector3.new(r.x1 + t, top, r.y1), POOL)
	end
	if not skip.z0 then
		Builders.box(ctx.model, f, Vector3.new(r.x0 - t, bottom, r.y0 - t), Vector3.new(r.x1 + t, top, r.y0), POOL)
	end
	if not skip.z1 then
		Builders.box(ctx.model, f, Vector3.new(r.x0 - t, bottom, r.y1), Vector3.new(r.x1 + t, top, r.y1 + t), POOL)
	end

	if opts and opts.steps then
		local count = math.floor(-bottom)
		Builders.straightStair(ctx.model, f * CFrame.new(r.x0 + 4, 0, r.y0), count, 1, 1.5, 6, bottom, POOL)
	end
end

-- Layouts ----------------------------------------------------------------------------

export type Layout = (ctx: Context) -> ()
local Layouts: { [string]: Layout } = {}
Chunks.Layouts = Layouts

-- Large columns standing in wide open water, with a clearing under a skylight.
local function columnHall(ctx: Context, allowPit: boolean)
	local radius = ctx.rng:NextNumber(2.2, 3.2)
	for _, x in { -24, -8, 8, 24 } do
		for _, z in { -24, -8, 8, 24 } do
			local inner = math.abs(x) == 8 and math.abs(z) == 8
			if not inner and ctx.rng:NextNumber() > 0.12 then
				Builders.pillar(ctx.model, ctx.frame * CFrame.new(x, 0, z), radius, 0, ctx.height)
			end
		end
	end
	if allowPit and ctx.rng:NextNumber() < 0.45 then
		addPit(ctx, rect(-12, -12, 12, 12), -6, { steps = true, rot = randomQuarter(ctx) })
	end
	addLightWell(ctx, 0, 0, 12, 10)
end

Layouts.ColumnHall = function(ctx)
	columnHall(ctx, true)
end

-- The spawn room: a calm column hall with no pool to fall into.
Layouts.Spawn = function(ctx)
	columnHall(ctx, false)
	local spawn = Instance.new("SpawnLocation")
	spawn.Anchored = true
	spawn.CanCollide = false
	spawn.Transparency = 1
	spawn.Size = Vector3.new(6, 1, 6)
	spawn.CFrame = ctx.frame * CFrame.new(0, 0.5, 0)
	spawn.Duration = 0
	spawn.Parent = ctx.model
end

-- Open deep pool with a walkway around it, pool steps and stepping platforms.
Layouts.DeepPool = function(ctx)
	local angle = randomQuarter(ctx)
	addPit(ctx, rect(-20, -20, 20, 20), ctx.deep, { steps = true, rot = angle })

	-- Square platforms rising just above the water (the steps occupy the -X/-Z
	-- corner of the rotated pit, so the spots are rotated the same way).
	local spots = { Vector3.new(8, 0, -8), Vector3.new(8, 0, 8), Vector3.new(-6, 0, 10), Vector3.new(10, 0, 0) }
	local rot = CFrame.Angles(0, angle, 0)
	for _ = 1, ctx.rng:NextInteger(0, 2) do
		local spot = rot * (table.remove(spots, ctx.rng:NextInteger(1, #spots)) :: Vector3)
		local f = ctx.frame * CFrame.new(spot)
		Builders.box(ctx.model, f, Vector3.new(-3, ctx.deep, -3), Vector3.new(3, ctx.water + 0.5, 3))
	end

	for _, x in { -24, 24 } do
		for _, z in { -24, 24 } do
			if ctx.rng:NextNumber() < 0.5 then
				Builders.pillar(ctx.model, ctx.frame * CFrame.new(x, 0, z), 2.5, 0, ctx.height)
			end
		end
	end
	addLightWell(ctx, 0, 0, 16, 10)
end

-- A hall of repeating curved archways over shallow water.
Layouts.ArchedHall = function(ctx)
	local f = ctx.frame * CFrame.Angles(0, ctx.rng:NextInteger(0, 1) * QUARTER, 0)
	local rise = ctx.rng:NextNumber(11, 15)
	for _, z in { -24, -8, 8, 24 } do
		Builders.archway(ctx.model, f * CFrame.new(0, 0, z), {
			totalWidth = 62,
			openingWidth = 44,
			springHeight = 6,
			rise = rise,
			height = ctx.height,
			depth = 3,
			segments = 18,
		})
	end
	addLightWell(ctx, 0, 0, 12, 10)
end

-- A spiral staircase climbing into a light shaft, beside a half-flooded pipe.
Layouts.SpiralRoom = function(ctx)
	local shaft = 20
	Builders.spiralStair(ctx.model, ctx.frame, {
		height = ctx.height + shaft - 8,
		startAngle = ctx.rng:NextNumber(0, 2 * math.pi),
	})
	addLightWell(ctx, 0, 0, 20, shaft)

	Builders.roundBore(ctx.model, ctx.frame * CFrame.Angles(0, randomQuarter(ctx), 0) * CFrame.new(0, 0, 18), {
		width = 28,
		height = ctx.height,
		depth = 12,
		radius = 6,
		centerY = 3,
	})
end

-- A grand staircase descending into a deep pool that drains into a dark tunnel.
Layouts.SunkenStair = function(ctx)
	local rot = randomQuarter(ctx)
	local f = ctx.frame * CFrame.Angles(0, rot, 0)
	local bottom = ctx.deep

	addPit(ctx, rect(-12, -24, 12, 20), bottom, { rot = rot, skip = { z1 = true } })
	Builders.straightStair(ctx.model, f * CFrame.new(0, 0, -24), -bottom, 1, 2, 16, bottom, POOL)

	-- Tunnel mass under the floor, forming the pool's far wall.
	local base = bottom - 1
	Builders.roundBore(ctx.model, f * CFrame.new(0, base, 25), {
		width = 26,
		height = -1 - base,
		depth = 10,
		radius = 5,
		centerY = 6.5, -- tunnel floor sits just above the pool floor
	})
	-- Flood the tunnel too, otherwise it would hold an air pocket.
	-- (runs to the chunk border so the region stays on the 4-stud voxel grid)
	table.insert(ctx.water_regions, { rect = rotateRect(rect(-8, 20, 8, 32), rot), y0 = bottom, y1 = ctx.water - 4 })

	addLightWell(ctx, 0, 0, 16, 10)
end

-- An atrium open to the sky: a tall tiled shaft lined with glowing windows.
Layouts.Atrium = function(ctx)
	addPit(ctx, rect(-12, -12, 12, 12), ctx.deep, { steps = true, rot = randomQuarter(ctx) })

	local open = 24
	table.insert(ctx.ceilingHoles, rect(-open, -open, open, open))

	local shaftHeight = 44
	local thickness = 2
	local windows: { Rect } = {}
	for _, x in { -18, -6, 6, 18 } do
		for _, y in { 6, 18, 30 } do
			table.insert(windows, { x0 = x - 2, x1 = x + 2, y0 = y, y1 = y + 6 })
		end
	end
	local glow: Builders.Props =
		{ material = Enum.Material.Neon, color = Color3.fromRGB(232, 246, 244), castShadow = false, name = "Window" }

	for k = 0, 3 do
		local width = if k % 2 == 0 then 2 * (open + thickness) else 2 * open
		local f = ctx.frame
			* CFrame.Angles(0, k * QUARTER, 0)
			* CFrame.new(0, ctx.height + Config.CEILING_THICKNESS, open + thickness / 2)
		Builders.wallWithHoles(ctx.model, f, width, shaftHeight, thickness, windows)
		for _, w in windows do
			Builders.box(ctx.model, f, Vector3.new(w.x0, w.y0, 0.5), Vector3.new(w.x1, w.y1, 1), glow)
		end
	end
end

-- Weighted layout table for everything except the origin chunk.
type Weight = { layout: string, weight: number }
local Weights: { Weight } = {
	{ layout = "ColumnHall", weight = 25 },
	{ layout = "ArchedHall", weight = 20 },
	{ layout = "DeepPool", weight = 18 },
	{ layout = "SunkenStair", weight = 13 },
	{ layout = "SpiralRoom", weight = 12 },
	{ layout = "Atrium", weight = 7 },
}
Chunks.Weights = Weights

function Chunks.pickLayout(roll: number): string
	local total = 0
	for _, w in Weights do
		total += w.weight
	end
	local target = roll * total
	for _, w in Weights do
		target -= w.weight
		if target <= 0 then
			return w.layout
		end
	end
	return Weights[1].layout
end

-- Build a whole chunk interior: layout, then floor and ceiling around its openings.
function Chunks.build(i: number, j: number, layoutName: string, rng: Random, parent: Instance?): Context
	local size = Config.CHUNK_SIZE
	local model = Instance.new("Model")
	model.Name = `Chunk_{i}_{j}_{layoutName}`

	local ctx: Context = {
		i = i,
		j = j,
		model = model,
		frame = CFrame.new(i * size, Config.FLOOR_Y, j * size),
		rng = rng,
		half = size / 2,
		height = Config.CEILING_Y - Config.FLOOR_Y,
		water = Config.WATER_Y - Config.FLOOR_Y,
		deep = Config.DEEP_FLOOR_Y - Config.FLOOR_Y,
		floorHoles = {},
		ceilingHoles = {},
		water_regions = {},
	}

	local layout = Layouts[layoutName]
	assert(layout, `unknown layout {layoutName}`)
	layout(ctx)

	local h = ctx.half
	local outer = rect(-h, -h, h, h)
	Builders.slabWithHoles(model, ctx.frame, outer, ctx.floorHoles, -Config.FLOOR_THICKNESS, 0)
	Builders.slabWithHoles(model, ctx.frame, outer, ctx.ceilingHoles, ctx.height, ctx.height + Config.CEILING_THICKNESS)

	-- The shallow water layer: exactly one voxel row ending at the water surface.
	table.insert(ctx.water_regions, { rect = outer, y0 = ctx.water - 4, y1 = ctx.water })

	model.Parent = parent
	return ctx
end

return Chunks
