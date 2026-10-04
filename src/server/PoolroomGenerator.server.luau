--!strict
-- Streams Poolroom chunks in and out around every player.
--
-- * Chunk (i, j) covers [i*S - S/2, i*S + S/2] x [j*S - S/2, j*S + S/2] (S = CHUNK_SIZE),
--   so chunks tile perfectly with no overlap or gaps.
-- * A chunk's layout is chosen from a hash of its coordinates, so the world is the
--   same no matter which order chunks load in, and unloaded chunks come back
--   identical when you return.
-- * Shared borders/corners (Joints) are reference counted: they exist while at
--   least one neighbouring chunk is loaded.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Poolrooms")
local Config = require(Shared:WaitForChild("Config"))
local Chunks = require(Shared:WaitForChild("Chunks"))
local Joints = require(Shared:WaitForChild("Joints"))
local Hash = require(Shared:WaitForChild("Hash"))

local SALT_LAYOUT = 1
local SALT_INTERIOR = 2

local S = Config.CHUNK_SIZE
local terrain = workspace.Terrain

local root = Instance.new("Folder")
root.Name = "Poolrooms"
root.Parent = workspace
local chunkFolder = Instance.new("Folder")
chunkFolder.Name = "Chunks"
chunkFolder.Parent = root
local jointFolder = Instance.new("Folder")
jointFolder.Name = "Joints"
jointFolder.Parent = root

type ChunkRecord = { i: number, j: number, model: Model }
type JointRecord = { model: Model, refs: number }

local chunks: { [string]: ChunkRecord } = {}
local joints: { [string]: JointRecord } = {}

local function chunkKey(i: number, j: number): string
	return `{i}:{j}`
end

local function layoutFor(i: number, j: number): string
	if i == 0 and j == 0 then
		return "Spawn"
	end
	return Chunks.pickLayout(Hash.unit(i, j, SALT_LAYOUT))
end

local function loadChunk(i: number, j: number)
	local key = chunkKey(i, j)
	if chunks[key] then
		return
	end

	local ctx = Chunks.build(i, j, layoutFor(i, j), Hash.random(i, j, SALT_INTERIOR), chunkFolder)

	-- Terrain water: every region is axis aligned and snapped to the 4-stud voxel grid.
	for _, w in ctx.water_regions do
		local r = w.rect
		local center = ctx.frame * Vector3.new((r.x0 + r.x1) / 2, (w.y0 + w.y1) / 2, (r.y0 + r.y1) / 2)
		terrain:FillBlock(CFrame.new(center), Vector3.new(r.x1 - r.x0, w.y1 - w.y0, r.y1 - r.y0), Enum.Material.Water)
	end

	for _, jointKey in Joints.keysForChunk(i, j) do
		local record = joints[jointKey]
		if record then
			record.refs += 1
		else
			joints[jointKey] = { model = Joints.build(jointKey, jointFolder), refs = 1 }
		end
	end

	chunks[key] = { i = i, j = j, model = ctx.model }
end

local function unloadChunk(key: string)
	local record = chunks[key]
	if not record then
		return
	end
	chunks[key] = nil
	record.model:Destroy()

	-- Remove this chunk's water (its footprint only; neighbours keep theirs).
	local y0 = Config.DEEP_FLOOR_Y - 4
	local y1 = Config.WATER_Y + 4
	terrain:FillBlock(
		CFrame.new(record.i * S, (y0 + y1) / 2, record.j * S),
		Vector3.new(S, y1 - y0, S),
		Enum.Material.Air
	)

	for _, jointKey in Joints.keysForChunk(record.i, record.j) do
		local joint = joints[jointKey]
		if joint then
			joint.refs -= 1
			if joint.refs <= 0 then
				joint.model:Destroy()
				joints[jointKey] = nil
			end
		end
	end
end

local function chunkCoord(position: Vector3): (number, number)
	return math.round(position.X / S), math.round(position.Z / S)
end

-- Grid positions that should stay loaded: every player, plus the spawn so that
-- respawning players always land on a floor.
local function focusPoints(): { { number } }
	local points = { { 0, 0 } }
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if rootPart and rootPart:IsA("BasePart") then
			local i, j = chunkCoord(rootPart.Position)
			table.insert(points, { i, j })
		end
	end
	return points
end

local function distanceToFocus(i: number, j: number, points: { { number } }): number
	local best = math.huge
	for _, p in points do
		best = math.min(best, math.max(math.abs(i - p[1]), math.abs(j - p[2])))
	end
	return best
end

local function step()
	local points = focusPoints()

	-- Load missing chunks, nearest first, a few per frame to avoid hitches.
	local missing: { { number } } = {}
	local seen: { [string]: boolean } = {}
	for _, p in points do
		for di = -Config.LOAD_RADIUS, Config.LOAD_RADIUS do
			for dj = -Config.LOAD_RADIUS, Config.LOAD_RADIUS do
				local i, j = p[1] + di, p[2] + dj
				local key = chunkKey(i, j)
				if not chunks[key] and not seen[key] then
					seen[key] = true
					table.insert(missing, { i, j, math.max(math.abs(di), math.abs(dj)) })
				end
			end
		end
	end
	table.sort(missing, function(a, b)
		return a[3] < b[3]
	end)
	for index, m in missing do
		loadChunk(m[1], m[2])
		if index % Config.CHUNKS_PER_STEP == 0 then
			task.wait()
		end
	end

	-- Unload chunks nobody is near (refresh positions: players moved while we built).
	points = focusPoints()
	for key, record in chunks do
		if distanceToFocus(record.i, record.j, points) > Config.UNLOAD_RADIUS then
			unloadChunk(key)
		end
	end
end

-- Build the spawn area right away so the first player never spawns over the void.
for i = -1, 1 do
	for j = -1, 1 do
		loadChunk(i, j)
	end
end

while true do
	step()
	task.wait(Config.UPDATE_INTERVAL)
end
