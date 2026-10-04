--!strict
-- Geometry primitives for the Poolrooms, built only from plain Parts so everything
-- can be generated at runtime (no meshes or packages required).
--
-- Every builder takes a `frame` CFrame and works in that local space:
--   +X = across, +Y = up, +Z = depth. `frame` sits at the BASE of the feature,
-- so features drop onto the floor by placing the frame at floor height.

local Config = require(script.Parent.Config)

local Builders = {}

export type Props = {
	color: Color3?,
	material: Enum.Material?,
	variant: string?,
	name: string?,
	canCollide: boolean?,
	castShadow: boolean?,
}

export type Rect = { x0: number, x1: number, y0: number, y1: number }

local EPS = 1e-3

-- Basic part ------------------------------------------------------------------

function Builders.part(parent: Instance, size: Vector3, cframe: CFrame, props: Props?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Size = size
	p.CFrame = cframe
	p.Material = (props and props.material) or Config.TILE_MATERIAL
	local variant = if props and props.variant ~= nil then props.variant else Config.TILE_VARIANT
	if p.Material == Config.TILE_MATERIAL then
		p.MaterialVariant = variant
	end
	p.Color = (props and props.color) or Config.TILE_COLOR
	p.Name = (props and props.name) or "Tile"
	if props and props.canCollide ~= nil then
		p.CanCollide = props.canCollide
	end
	if props and props.castShadow ~= nil then
		p.CastShadow = props.castShadow
	end
	p.Parent = parent
	return p
end

-- Axis-aligned box (in `frame` space) given two opposite corners.
function Builders.box(parent: Instance, frame: CFrame, a: Vector3, b: Vector3, props: Props?): Part?
	local lo, hi = a:Min(b), a:Max(b)
	local size = hi - lo
	if size.X < EPS or size.Y < EPS or size.Z < EPS then
		return nil
	end
	return Builders.part(parent, size, frame * CFrame.new((lo + hi) / 2), props)
end

-- A thin beam between two points (handrails etc.).
function Builders.beam(parent: Instance, p0: Vector3, p1: Vector3, thickness: number, props: Props?): Part
	local length = (p1 - p0).Magnitude
	local cf = CFrame.lookAt((p0 + p1) / 2, p1)
	return Builders.part(parent, Vector3.new(thickness, thickness, length), cf, props)
end

-- Rectangle subtraction ---------------------------------------------------------
-- Returns rectangles covering `outer` minus `holes`, merged into as few parts as
-- practical. Used for walls with doors/windows and floors/ceilings with openings.

function Builders.rectDifference(outer: Rect, holes: { Rect }): { Rect }
	local xs = { outer.x0, outer.x1 }
	for _, h in holes do
		if h.x0 > outer.x0 and h.x0 < outer.x1 then
			table.insert(xs, h.x0)
		end
		if h.x1 > outer.x0 and h.x1 < outer.x1 then
			table.insert(xs, h.x1)
		end
	end
	table.sort(xs)

	local result: { Rect } = {}
	local open: { [string]: Rect } = {}
	for i = 1, #xs - 1 do
		local a, b = xs[i], xs[i + 1]
		if b - a > EPS then
			local mid = (a + b) / 2
			local cuts = {}
			for _, h in holes do
				if h.x0 < mid and h.x1 > mid then
					table.insert(cuts, { math.max(h.y0, outer.y0), math.min(h.y1, outer.y1) })
				end
			end
			table.sort(cuts, function(c1, c2)
				return c1[1] < c2[1]
			end)

			local free = {}
			local y = outer.y0
			for _, c in cuts do
				if c[1] > y + EPS then
					table.insert(free, { y, c[1] })
				end
				y = math.max(y, c[2])
			end
			if outer.y1 > y + EPS then
				table.insert(free, { y, outer.y1 })
			end

			-- Extend rectangles from the previous strip when the interval matches.
			local nextOpen: { [string]: Rect } = {}
			for _, f in free do
				local key = `{f[1]}:{f[2]}`
				local existing = open[key]
				if existing then
					existing.x1 = b
					nextOpen[key] = existing
				else
					local r: Rect = { x0 = a, x1 = b, y0 = f[1], y1 = f[2] }
					table.insert(result, r)
					nextOpen[key] = r
				end
			end
			open = nextOpen
		end
	end
	return result
end

-- Vertical wall in frame space: X in [-width/2, width/2], Y in [0, height],
-- centered on Z. Holes are rects in the same X/Y space.
function Builders.wallWithHoles(
	parent: Instance,
	frame: CFrame,
	width: number,
	height: number,
	thickness: number,
	holes: { Rect },
	props: Props?
)
	local outer = { x0 = -width / 2, x1 = width / 2, y0 = 0, y1 = height }
	for _, r in Builders.rectDifference(outer, holes) do
		Builders.box(parent, frame, Vector3.new(r.x0, r.y0, -thickness / 2), Vector3.new(r.x1, r.y1, thickness / 2), props)
	end
end

-- Horizontal slab between y0 and y1 covering outer (x/z) minus holes (x/z).
-- Rect fields are reused: x0/x1 = X, y0/y1 = Z.
function Builders.slabWithHoles(
	parent: Instance,
	frame: CFrame,
	outer: Rect,
	holes: { Rect },
	y0: number,
	y1: number,
	props: Props?
)
	for _, r in Builders.rectDifference(outer, holes) do
		Builders.box(parent, frame, Vector3.new(r.x0, y0, r.y0), Vector3.new(r.x1, y1, r.y1), props)
	end
end

-- Curved band -------------------------------------------------------------------
-- Approximates an elliptical curve (center (0, cy), radii rx/ry) from angle t0 to
-- t1 with flat segments of radial thickness `thick`, extruded from z0 to z1.
-- The inner faces of the segments lie exactly on the curve's chords, so the
-- underside of arches and the inside of tunnels read as a smooth surface.

function Builders.curvedBand(
	parent: Instance,
	frame: CFrame,
	cy: number,
	rx: number,
	ry: number,
	t0: number,
	t1: number,
	segments: number,
	thick: number,
	z0: number,
	z1: number,
	props: Props?
)
	local depth = z1 - z0
	local zc = (z0 + z1) / 2
	for i = 0, segments - 1 do
		local a0 = t0 + (t1 - t0) * i / segments
		local a1 = t0 + (t1 - t0) * (i + 1) / segments
		local p0 = Vector2.new(rx * math.cos(a0), cy + ry * math.sin(a0))
		local p1 = Vector2.new(rx * math.cos(a1), cy + ry * math.sin(a1))
		local d = p1 - p0
		local len = d.Magnitude
		local dir = d / len
		local normal = Vector2.new(dir.Y, -dir.X) -- outward for counter-clockwise travel
		local c = (p0 + p1) / 2 + normal * (thick / 2)
		local angle = math.atan2(dir.Y, dir.X)
		-- Neighbouring segments overlap in small wedges at their outer corners; giving
		-- every other one a hair less depth keeps those wedges from z-fighting.
		local segmentDepth = if i % 2 == 1 then depth - 0.04 else depth
		Builders.part(
			parent,
			Vector3.new(len + 0.05, thick, segmentDepth),
			frame * CFrame.new(c.X, c.Y, zc) * CFrame.Angles(0, 0, angle),
			props
		)
	end
end

-- Archway -----------------------------------------------------------------------
-- A wall of `totalWidth` x `height` with a semi-elliptical arched opening.
-- Below `springHeight` the opening is rectangular; above it the arch rises by
-- `rise`. The spandrels (solid area above the curve) are filled with vertical
-- slices whose width never exceeds the band thickness, so no gaps can show.

export type ArchOptions = {
	totalWidth: number,
	openingWidth: number,
	springHeight: number,
	rise: number,
	height: number,
	depth: number,
	segments: number?,
	band: number?,
	props: Props?,
}

function Builders.archway(parent: Instance, frame: CFrame, o: ArchOptions)
	local a = o.openingWidth / 2
	local half = o.totalWidth / 2
	local d = o.depth
	local band = o.band or 3
	local props = o.props

	-- Piers either side of the opening.
	Builders.box(parent, frame, Vector3.new(-half, 0, -d / 2), Vector3.new(-a, o.height, d / 2), props)
	Builders.box(parent, frame, Vector3.new(a, 0, -d / 2), Vector3.new(half, o.height, d / 2), props)

	-- Spandrel slices.
	local slices = math.max(2, math.ceil(o.openingWidth / math.min(2, band)))
	local w = o.openingWidth / slices
	for i = 0, slices - 1 do
		local x0 = -a + i * w
		local x1 = x0 + w
		local nearest = if x0 < 0 and x1 > 0 then 0 else math.min(math.abs(x0), math.abs(x1))
		local bottom = o.springHeight + o.rise * math.sqrt(math.max(0, 1 - (nearest / a) ^ 2))
		Builders.box(parent, frame, Vector3.new(x0, bottom, -d / 2), Vector3.new(x1, o.height, d / 2), props)
	end

	-- Smooth intrados.
	-- (inset 0.05 so its faces never sit coplanar with the slices' faces)
	Builders.curvedBand(parent, frame, o.springHeight, a, o.rise, 0, math.pi, o.segments or 16, band, -d / 2 + 0.05, d / 2 - 0.05, props)
end

-- Round bore --------------------------------------------------------------------
-- A solid block (width x height x depth) with a circular tunnel bored through it
-- along Z. The far end is capped with a dark disk so the tunnel reads as endless.
-- Inner rings darken toward the back to sell the depth.

export type BoreOptions = {
	width: number,
	height: number,
	depth: number,
	radius: number,
	centerY: number,
	segments: number?,
	sections: number?,
}

function Builders.roundBore(parent: Instance, frame: CFrame, o: BoreOptions)
	local r = o.radius
	local half = o.width / 2
	local d = o.depth
	local band = 3
	-- Everything stops at zBack, where a full-size back plate closes the block. Keeping
	-- the plate separate (not overlapping) means no two faces ever share a plane.
	local plate = 0.4
	local z0, zBack = -d / 2, d / 2 - plate

	-- Solid mass left and right of the bore.
	Builders.box(parent, frame, Vector3.new(-half, 0, z0), Vector3.new(-r, o.height, zBack))
	Builders.box(parent, frame, Vector3.new(r, 0, z0), Vector3.new(half, o.height, zBack))

	-- Columns above and below the bore.
	local slices = math.max(2, math.ceil(2 * r / 2))
	local w = 2 * r / slices
	for i = 0, slices - 1 do
		local x0 = -r + i * w
		local x1 = x0 + w
		local nearest = if x0 < 0 and x1 > 0 then 0 else math.min(math.abs(x0), math.abs(x1))
		local h = math.sqrt(math.max(0, r * r - nearest * nearest))
		Builders.box(parent, frame, Vector3.new(x0, o.centerY + h, z0), Vector3.new(x1, o.height, zBack))
		if o.centerY - h > 0 then
			Builders.box(parent, frame, Vector3.new(x0, 0, z0), Vector3.new(x1, o.centerY - h, zBack))
		end
	end

	-- Tunnel lining, fading from tile white to near-black.
	local sections = o.sections or 4
	local liningStart, liningEnd = z0 + 0.05, zBack - 0.05
	local sectionDepth = (liningEnd - liningStart) / sections
	for s = 0, sections - 1 do
		local t = s / sections
		local color = Config.TILE_COLOR:Lerp(Config.VOID_COLOR, math.min(1, t * t * 1.3))
		local zs = liningStart + s * sectionDepth
		Builders.curvedBand(parent, frame, o.centerY, r, r, 0, 2 * math.pi, o.segments or 20, band, zs, zs + sectionDepth, {
			color = color,
		})
	end

	-- Dark cap + back plate.
	Builders.part(
		parent,
		Vector3.new(0.4, 2 * r + 0.5, 2 * r + 0.5),
		frame * CFrame.new(0, o.centerY, zBack - 0.25) * CFrame.Angles(0, math.pi / 2, 0),
		{ color = Config.VOID_COLOR, material = Enum.Material.SmoothPlastic, name = "Void" }
	).Shape = Enum.PartType.Cylinder
	Builders.box(parent, frame, Vector3.new(-half, 0, zBack), Vector3.new(half, o.height, d / 2))
end

-- Pillar ------------------------------------------------------------------------

function Builders.pillar(parent: Instance, frame: CFrame, radius: number, y0: number, y1: number, props: Props?): Part
	local p = Builders.part(
		parent,
		Vector3.new(y1 - y0, radius * 2, radius * 2),
		frame * CFrame.new(0, (y0 + y1) / 2, 0) * CFrame.Angles(0, 0, math.pi / 2),
		props
	)
	p.Shape = Enum.PartType.Cylinder
	p.Name = "Pillar"
	return p
end

-- Spiral staircase ----------------------------------------------------------------

export type SpiralOptions = {
	height: number,
	coreRadius: number?,
	stepLength: number?,
	stepRise: number?,
	degreesPerStep: number?,
	startAngle: number?,
	railing: boolean?,
}

function Builders.spiralStair(parent: Instance, frame: CFrame, o: SpiralOptions)
	local core = o.coreRadius or 2.5
	local len = o.stepLength or 6
	local rise = o.stepRise or 1
	local step = math.rad(o.degreesPerStep or 18)
	local start = o.startAngle or 0
	local outer = core + len
	local thickness = 0.8
	local width = outer * step * 1.15 -- slight overlap so the outer edge is continuous

	Builders.pillar(parent, frame, core, 0, o.height)

	local count = math.floor(o.height / rise)
	local railProps: Props = { material = Enum.Material.SmoothPlastic, color = Color3.fromRGB(232, 232, 226), castShadow = false }
	local lastTop: Vector3? = nil
	for i = 1, count do
		local angle = start + i * step
		local top = i * rise
		local stepFrame = frame * CFrame.Angles(0, angle, 0)
		Builders.part(
			parent,
			Vector3.new(len + 0.5, thickness, width),
			stepFrame * CFrame.new(core + len / 2 - 0.25, top - thickness / 2, 0),
			{ name = "Step" }
		)

		if o.railing ~= false then
			local base = (stepFrame * CFrame.new(outer - 0.3, top, 0)).Position
			local railTop = base + Vector3.new(0, 3.2, 0)
			if i % 2 == 0 then
				Builders.beam(parent, base, railTop, 0.2, railProps)
			end
			if lastTop then
				Builders.beam(parent, lastTop, railTop, 0.25, railProps)
			end
			lastTop = railTop
		end
	end
end

-- Straight staircase descending along +Z ------------------------------------------
-- Step i has its top at -i*rise; each step is solid down to `bottomY`.

function Builders.straightStair(
	parent: Instance,
	frame: CFrame,
	steps: number,
	rise: number,
	run: number,
	width: number,
	bottomY: number,
	props: Props?
)
	for i = 1, steps do
		local top = -i * rise
		Builders.box(
			parent,
			frame,
			Vector3.new(-width / 2, bottomY, (i - 1) * run),
			Vector3.new(width / 2, top, i * run),
			props
		)
	end
end

-- Light well ----------------------------------------------------------------------
-- A square shaft rising out of a ceiling opening, capped with a glowing panel and
-- a downward SurfaceLight: "daylight from a hidden opening". `frame` sits at the
-- underside of the ceiling, centered on the opening. The shaft walls start above
-- the ceiling slab so their faces never overlap the slab's hole edges.

function Builders.lightWell(parent: Instance, frame: CFrame, size: number, depth: number)
	local h = size / 2
	local t = 1
	local y0 = Config.CEILING_THICKNESS
	Builders.box(parent, frame, Vector3.new(-h - t, y0, -h - t), Vector3.new(h + t, depth, -h))
	Builders.box(parent, frame, Vector3.new(-h - t, y0, h), Vector3.new(h + t, depth, h + t))
	Builders.box(parent, frame, Vector3.new(-h - t, y0, -h), Vector3.new(-h, depth, h))
	Builders.box(parent, frame, Vector3.new(h, y0, -h), Vector3.new(h + t, depth, h))

	local panel = Builders.part(
		parent,
		Vector3.new(size + 2 * t, 1, size + 2 * t),
		frame * CFrame.new(0, depth + 0.5, 0),
		{ material = Enum.Material.Neon, color = Config.LIGHT_PANEL_COLOR, name = "Skylight", castShadow = false }
	)
	local light = Instance.new("SurfaceLight")
	light.Face = Enum.NormalId.Bottom
	light.Angle = 80
	light.Brightness = Config.SKYLIGHT_BRIGHTNESS
	light.Range = Config.SKYLIGHT_RANGE
	light.Shadows = Config.SKYLIGHT_SHADOWS
	light.Color = Color3.fromRGB(255, 248, 232)
	light.Parent = panel
end

return Builders
