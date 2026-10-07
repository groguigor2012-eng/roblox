local Vector3 = require("@lune/roblox").Vector3
return function(H)
	local UndergroundRouter = H.Module("Server.AI.UndergroundRouter")

	-- 40 x 40 cell grid (cell size 4) with a bedrock wall at x in [60, 64) except a gap.
	local function makeRouter(blocked: (number, number) -> boolean, expansions: number?)
		return UndergroundRouter.new({
			MinX = 0,
			MinZ = 0,
			MaxX = 160,
			MaxZ = 160,
			FloorY = 0,
			CellSize = 4,
			MaxExpansions = expansions or 10000,
			Probe = function(x, z)
				return not blocked(x, z)
			end,
		})
	end

	local function wallWithGap(x, z)
		return x >= 60 and x < 68 and not (z >= 140 and z < 152)
	end

	H.test("finds a tunnel around bedrock", function()
		local router = makeRouter(wallWithGap)
		local path = router:FindPath(Vector3.new(10, 0, 10), Vector3.new(120, 0, 10))
		H.ok(path and #path > 0, "path expected")
		local last = path[#path]
		H.ok((last - Vector3.new(120, 0, 10)).Magnitude < 6, "ends at the goal")
		-- Every segment must stay on diggable ground.
		local previous = Vector3.new(10, 0, 10)
		for _, point in path do
			H.ok(router:IsDiggableAt(point), "waypoint on bedrock")
			local steps = math.ceil((point - previous).Magnitude)
			for i = 0, steps do
				local p = previous:Lerp(point, i / math.max(1, steps))
				H.ok(not wallWithGap(p.X, p.Z), "segment crosses bedrock")
			end
			previous = point
		end
		local crossed = false
		for _, point in path do
			if point.Z >= 136 then
				crossed = true
			end
		end
		H.ok(crossed, "the only way through is the gap near z=146")
	end)

	H.test("returns nil when the target is sealed off", function()
		local sealed = function(x, z)
			return x >= 60 and x < 68
		end
		H.eq(makeRouter(sealed):FindPath(Vector3.new(10, 0, 10), Vector3.new(120, 0, 10)), nil)
	end)

	H.test("respects map bounds and the expansion budget", function()
		local router = makeRouter(function() return false end, 5)
		H.ok(not router:IsDiggableAt(Vector3.new(-5, 0, 10)), "outside bounds is never diggable")
		H.eq(router:FindPath(Vector3.new(2, 0, 2), Vector3.new(150, 0, 150)), nil, "budget exceeded")
	end)

	H.test("no diagonal corner cutting between bedrock cells", function()
		-- Bedrock at cells (5,6) and (6,5): moving (5,5)->(6,6) diagonally would squeeze between.
		local function blocked(x, z)
			local cx, cz = math.floor(x / 4), math.floor(z / 4)
			return (cx == 5 and cz == 6) or (cx == 6 and cz == 5)
		end
		local router = makeRouter(blocked)
		local path = router:FindPath(Vector3.new(22, 0, 22), Vector3.new(26, 0, 26))
		H.ok(path ~= nil, "a detour exists")
		H.ok(#path >= 2, "must detour instead of squeezing diagonally")
		local previous = Vector3.new(22, 0, 22)
		for _, point in path do
			for i = 0, 20 do
				local p = previous:Lerp(point, i / 20)
				H.ok(not blocked(p.X, p.Z), "tunnel passes through bedrock")
			end
			previous = point
		end
	end)

	H.test("probes are cached per cell", function()
		local router = makeRouter(function() return false end)
		router:FindPath(Vector3.new(2, 0, 2), Vector3.new(60, 0, 60))
		local probes = router:GetProbeCount()
		router:FindPath(Vector3.new(2, 0, 2), Vector3.new(60, 0, 60))
		H.eq(router:GetProbeCount(), probes, "second identical search must not raycast again")
	end)

	H.test("resurface point is next to the target and free", function()
		local router = makeRouter(function() return false end)
		local target = Vector3.new(80, 0, 80)
		local point = router:FindResurfacePoint(target, function(candidate)
			return (candidate - Vector3.new(83.5, 0, 80)).Magnitude > 0.5 -- first ring point occupied
		end)
		H.ok(point ~= nil)
		local distance = (point - target).Magnitude
		H.ok(distance >= 3 and distance <= 8, `distance {distance}`)
	end)
end
