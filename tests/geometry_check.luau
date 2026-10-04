local roblox = require("@lune/roblox")
local Instance, Vector3, Enum = roblox.Instance, roblox.Vector3, roblox.Enum
local Random = require("./random")
local Config = require("./.mods/Config")
local Chunks = require("./.mods/Chunks")
local Joints = require("./.mods/Joints")
local Builders = require("./.mods/Builders")
local Hash = require("./.mods/Hash")

local failures = 0
local function fail(msg)
	failures += 1
	print("FAIL: " .. msg)
end

local function snap(v) return math.round(v * 1000) / 1000 end
local function aabb(p)
	local cf, s = p.CFrame, p.Size
	local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
	for _, v in { r, u, l } do
		for _, c in { v.X, v.Y, v.Z } do
			if math.abs(c) > 1e-4 and math.abs(math.abs(c) - 1) > 1e-4 then return nil end
		end
	end
	local half = Vector3.new(
		math.abs(r.X) * s.X + math.abs(u.X) * s.Y + math.abs(l.X) * s.Z,
		math.abs(r.Y) * s.X + math.abs(u.Y) * s.Y + math.abs(l.Y) * s.Z,
		math.abs(r.Z) * s.X + math.abs(u.Z) * s.Y + math.abs(l.Z) * s.Z) / 2
	local c = cf.Position
	return { lo = { snap(c.X - half.X), snap(c.Y - half.Y), snap(c.Z - half.Z) }, hi = { snap(c.X + half.X), snap(c.Y + half.Y), snap(c.Z + half.Z) } }
end

local function parts(root)
	local out = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then table.insert(out, d) end
	end
	return out
end

-- Coplanar faces facing the same way that overlap => z-fighting.
local function zfight(list, label)
	local boxes = {}
	for _, p in list do
		if p.ClassName == "Part" and p.Shape == Enum.PartType.Block then
			local b = aabb(p)
			if b then table.insert(boxes, { b = b, p = p }) end
		end
	end
	local count = 0
	for a = 1, #boxes do
		for b = a + 1, #boxes do
			local A, B = boxes[a].b, boxes[b].b
			for axis = 1, 3 do
				local o1, o2 = axis % 3 + 1, (axis + 1) % 3 + 1
				local ov1 = math.min(A.hi[o1], B.hi[o1]) - math.max(A.lo[o1], B.lo[o1])
				local ov2 = math.min(A.hi[o2], B.hi[o2]) - math.max(A.lo[o2], B.lo[o2])
				if ov1 > 0.01 and ov2 > 0.01 then
					for _, side in { "lo", "hi" } do
						local plane = A[side][axis]
						-- Tops flush with the ceiling underside / bottoms on the floor are hidden.
						local hidden = axis == 2 and ((side == "hi" and plane == Config.CEILING_Y) or (side == "lo" and plane == Config.FLOOR_Y))
						if not hidden and math.abs(plane - B[side][axis]) < 1e-3 then
							count += 1
							if count <= 6 then
								print(string.format("  zfight %s axis=%d %s at %.2f: %s %s | %s %s", label, axis, side, A[side][axis],
									boxes[a].p.Name, tostring(boxes[a].p.Size), boxes[b].p.Name, tostring(boxes[b].p.Size)))
							end
						end
					end
				end
			end
		end
	end
	return count
end

-- 1. rectDifference covers exactly outer minus holes.
do
	local outer = { x0 = -32, x1 = 32, y0 = -32, y1 = 32 }
	local holes = { { x0 = -6, x1 = 6, y0 = -6, y1 = 6 }, { x0 = 10, x1 = 40, y0 = -20, y1 = -10 } }
	local area = 0
	for _, r in Builders.rectDifference(outer, holes) do area += (r.x1 - r.x0) * (r.y1 - r.y0) end
	local expected = 64 * 64 - 144 - 22 * 10
	if math.abs(area - expected) > 1e-6 then fail(`rectDifference area {area} ~= {expected}`) end
end

-- 2. Every layout builds, stays inside its chunk, and has no z-fighting.
local S = Config.CHUNK_SIZE
local totalParts, chunksBuilt = 0, 0
for name in Chunks.Layouts do
	local worst = 0
	for trial = 1, 8 do
		local i, j = trial * 3 - 7, trial % 4 - 2
		local ctx = Chunks.build(i, j, name, Random.new(trial * 97 + #name), nil)
		local list = parts(ctx.model)
		totalParts += #list
		chunksBuilt += 1
		worst = math.max(worst, #list)
		for _, p in list do
			if p.Size.X <= 0 or p.Size.Y <= 0 or p.Size.Z <= 0 then fail(`{name}: zero-size part {p.Name}`) end
			local rel = p.CFrame.Position - ctx.frame.Position
			if math.abs(rel.X) > S / 2 + 0.01 or math.abs(rel.Z) > S / 2 + 0.01 then
				fail(`{name}: part {p.Name} centered outside chunk at {rel}`)
			end
		end
		local zf = zfight(list, name)
		if zf > 0 then fail(`{name} trial {trial}: {zf} coplanar overlapping faces`) end
		for _, w in ctx.water_regions do
			for _, v in { w.rect.x0 + i * S, w.rect.x1 + i * S, w.rect.y0 + j * S, w.rect.y1 + j * S, w.y0 + Config.FLOOR_Y, w.y1 + Config.FLOOR_Y } do
				if v % 4 ~= 0 then
					print(`  note: {name} water bound {v} not voxel aligned`)
				end
			end
		end
	end
	print(string.format("%-12s ok (max %d parts)", name, worst))
end

-- 3. Joints build for every style; corners + edges; z-fighting within each.
local styles = {}
for a = -6, 6 do
	for b = -6, 6 do
		for _, kind in { "X", "Z", "C" } do
			local key = `{kind}:{a}:{b}`
			local m = Joints.build(key, nil)
			local list = parts(m)
			totalParts += #list
			if kind ~= "C" then styles[Joints.edgeStyle(kind, a, b)] = (styles[Joints.edgeStyle(kind, a, b)] or 0) + 1 end
			local zf = zfight(list, key)
			if zf > 0 then fail(`{key}: {zf} coplanar faces`) end
		end
	end
end
for k, v in styles do print(`edge style {k}: {v}`) end

-- 4. A whole loaded neighbourhood (chunks + joints) has no z-fighting between pieces.
do
	local world = Instance.new("Folder")
	for i = -1, 1 do
		for j = -1, 1 do
			local layout = if i == 0 and j == 0 then "Spawn" else Chunks.pickLayout(Hash.unit(i, j, 1))
			Chunks.build(i, j, layout, Random.new(i * 31 + j), world)
		end
	end
	local seen = {}
	for i = -1, 1 do
		for j = -1, 1 do
			for _, key in Joints.keysForChunk(i, j) do
				if not seen[key] then seen[key] = true; Joints.build(key, world) end
			end
		end
	end
	local zf = zfight(parts(world), "world")
	print(`3x3 neighbourhood: {#parts(world)} parts, {zf} coplanar overlaps`)
end

-- 5. Connectivity: every chunk within radius 20 reachable from the origin.
do
	local R = 20
	local passable = function(kind, a, b) return Joints.edgeStyle(kind, a, b) ~= "wall" end
	local seen, queue, head = { ["0:0"] = true }, { { 0, 0 } }, 1
	while head <= #queue do
		local c = queue[head]; head += 1
		local i, j = c[1], c[2]
		local nbrs = {
			{ i + 1, j, passable("X", i, j) }, { i - 1, j, passable("X", i - 1, j) },
			{ i, j + 1, passable("Z", i, j) }, { i, j - 1, passable("Z", i, j - 1) },
		}
		for _, n in nbrs do
			local key = `{n[1]}:{n[2]}`
			if n[3] and not seen[key] and math.abs(n[1]) <= R and math.abs(n[2]) <= R then
				seen[key] = true
				table.insert(queue, { n[1], n[2] })
			end
		end
	end
	local reached = #queue
	if reached ~= (2 * R + 1) ^ 2 then fail(`only {reached} of {(2 * R + 1) ^ 2} chunks reachable`) else print(`connectivity ok: {reached} chunks`) end
	local counts = {}
	for i = -R, R do for j = -R, R do
		local l = Chunks.pickLayout(Hash.unit(i, j, 1)); counts[l] = (counts[l] or 0) + 1
	end end
	for k, v in counts do print(`layout {k}: {v}`) end
end

print(`built {chunksBuilt} test chunks, {totalParts} parts total`)
print(if failures == 0 then "ALL CHECKS PASSED" else `{failures} FAILURES`)
