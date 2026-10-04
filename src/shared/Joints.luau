--!strict
-- Joints are the pieces shared by neighbouring chunks: the wall/archway/doorway on
-- each border ("edges") and the square pier where four chunks meet ("corners").
--
-- Keys:
--   X:a:j  edge on the boundary between chunk (a, j) and (a + 1, j)
--   Z:i:b  edge on the boundary between chunk (i, b) and (i, b + 1)
--   C:a:b  corner between chunks (a..a+1, b..b+1)
--
-- An edge's style comes only from its key + the seed, so whichever neighbour loads
-- first, both sides agree. Connectivity is guaranteed: every chunk has one
-- "parent" edge pointing toward the origin that is always passable, which links
-- the whole infinite grid into one tree with no sealed-off rooms.

local Config = require(script.Parent.Config)
local Builders = require(script.Parent.Builders)
local Hash = require(script.Parent.Hash)

local Joints = {}

local SALT_STYLE = 11
local SALT_DETAIL = 12

local function sign(n: number): number
	return if n > 0 then 1 elseif n < 0 then -1 else 0
end

-- The always-open edge leading from chunk (i, j) one step closer to the origin.
local function parentEdge(i: number, j: number): string?
	if i == 0 and j == 0 then
		return nil
	end
	if math.abs(i) >= math.abs(j) then
		return `X:{math.min(i, i - sign(i))}:{j}`
	end
	return `Z:{i}:{math.min(j, j - sign(j))}`
end

function Joints.keysForChunk(i: number, j: number): { string }
	return {
		`X:{i - 1}:{j}`,
		`X:{i}:{j}`,
		`Z:{i}:{j - 1}`,
		`Z:{i}:{j}`,
		`C:{i - 1}:{j - 1}`,
		`C:{i}:{j - 1}`,
		`C:{i - 1}:{j}`,
		`C:{i}:{j}`,
	}
end

local function parse(key: string): (string, number, number)
	local kind, a, b = string.match(key, "^(%a):(%-?%d+):(%-?%d+)$")
	assert(kind and a and b, `bad joint key {key}`)
	return kind, tonumber(a) :: number, tonumber(b) :: number
end

export type EdgeStyle = "open" | "arcade" | "door" | "alcove" | "wall"

function Joints.edgeStyle(kind: string, a: number, b: number): EdgeStyle
	local key = `{kind}:{a}:{b}`
	local forced
	if kind == "X" then
		forced = parentEdge(a, b) == key or parentEdge(a + 1, b) == key
	else
		forced = parentEdge(a, b) == key or parentEdge(a, b + 1) == key
	end

	local roll = Hash.unit(a, b, SALT_STYLE + (if kind == "X" then 0 else 100))
	local style: EdgeStyle
	if roll < 0.25 then
		style = "open"
	elseif roll < 0.55 then
		style = "arcade"
	elseif roll < 0.75 then
		style = "door"
	elseif roll < 0.9 then
		style = "alcove"
	else
		style = "wall"
	end
	if forced and style == "wall" then
		style = "arcade"
	end
	return style
end

-- Edge builders. Frame: centered on the border at floor height, local X along the border.

local function buildOpen(model: Model, frame: CFrame, height: number)
	-- A shallow beam under the ceiling keeps the rhythm of the grid visible.
	-- It stops at the corner piers (2.5 studs) so crossing beams never overlap.
	local half = Config.CHUNK_SIZE / 2 - 2.5
	Builders.box(model, frame, Vector3.new(-half, height - 2, -1), Vector3.new(half, height, 1))
end

local function buildArcade(model: Model, frame: CFrame, height: number)
	local bay = Config.CHUNK_SIZE / 4
	for k = 0, 3 do
		local x = -Config.CHUNK_SIZE / 2 + bay * (k + 0.5)
		Builders.archway(model, frame * CFrame.new(x, 0, 0), {
			totalWidth = bay,
			openingWidth = bay - 6,
			springHeight = 5,
			rise = (bay - 6) / 2,
			height = height,
			depth = 3,
			segments = 10,
			band = 2,
		})
	end
end

local function buildDoor(model: Model, frame: CFrame, height: number, rng: Random)
	local holes: { Builders.Rect } = {}
	local spots = { -16, 0, 16 }
	local count = rng:NextInteger(1, 2)
	for _ = 1, count do
		local x = table.remove(spots, rng:NextInteger(1, #spots)) :: number
		table.insert(holes, { x0 = x - 4, x1 = x + 4, y0 = 0, y1 = 14 })
	end
	Builders.wallWithHoles(model, frame, Config.CHUNK_SIZE, height, Config.WALL_THICKNESS, holes)
end

local function buildAlcove(model: Model, frame: CFrame, height: number, rng: Random)
	local t = Config.THICK_WALL
	-- Flip so the blind niches face a random side.
	local f = if rng:NextNumber() < 0.5 then frame else frame * CFrame.Angles(0, math.pi, 0)
	local holes: { Builders.Rect } = {}
	-- Low walk-through openings at water level.
	for _, x in { -21, -7, 7, 21 } do
		table.insert(holes, { x0 = x - 3, x1 = x + 3, y0 = 0, y1 = 7 })
	end
	-- Upper row of blind niches, closed at the back.
	local niches: { Builders.Rect } = {}
	for _, x in { -14, 0, 14 } do
		local r = { x0 = x - 3, x1 = x + 3, y0 = 10, y1 = 16 }
		table.insert(holes, r)
		table.insert(niches, r)
	end
	Builders.wallWithHoles(model, f, Config.CHUNK_SIZE, height, t, holes)
	for _, r in niches do
		Builders.box(model, f, Vector3.new(r.x0, r.y0, t / 2 - 1), Vector3.new(r.x1, r.y1, t / 2))
	end
end

local function buildWall(model: Model, frame: CFrame, height: number)
	Builders.wallWithHoles(model, frame, Config.CHUNK_SIZE, height, Config.WALL_THICKNESS, {})
end

function Joints.build(key: string, parent: Instance?): Model
	local kind, a, b = parse(key)
	local size = Config.CHUNK_SIZE
	local height = Config.CEILING_Y - Config.FLOOR_Y
	local model = Instance.new("Model")

	if kind == "C" then
		model.Name = `Corner_{a}_{b}`
		local frame = CFrame.new((a + 0.5) * size, Config.FLOOR_Y, (b + 0.5) * size)
		-- 5 studs wide so its faces never coincide with a 4-stud alcove wall's faces.
		Builders.box(model, frame, Vector3.new(-2.5, 0, -2.5), Vector3.new(2.5, height, 2.5), { name = "Pier" })
	else
		local frame = if kind == "X"
			then CFrame.new((a + 0.5) * size, Config.FLOOR_Y, b * size) * CFrame.Angles(0, math.pi / 2, 0)
			else CFrame.new(a * size, Config.FLOOR_Y, (b + 0.5) * size)
		local style = Joints.edgeStyle(kind, a, b)
		local rng = Hash.random(a, b, SALT_DETAIL + (if kind == "X" then 0 else 100))
		model.Name = `Edge_{key}_{style}`

		if style == "open" then
			buildOpen(model, frame, height)
		elseif style == "arcade" then
			buildArcade(model, frame, height)
		elseif style == "door" then
			buildDoor(model, frame, height, rng)
		elseif style == "alcove" then
			buildAlcove(model, frame, height, rng)
		else
			buildWall(model, frame, height)
		end
	end

	model.Parent = parent
	return model
end

return Joints
