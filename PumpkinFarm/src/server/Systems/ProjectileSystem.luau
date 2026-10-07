--!strict
--[[
	ProjectileSystem
	Path: ServerScriptService.Server.Systems.ProjectileSystem

	Authoritative projectile simulation without physics parts. Every projectile is a
	point (with radius) moved analytically on one shared Heartbeat; each step raycasts
	the segment it travelled against the static world and checks enemies/players
	through the registries (crows and buried moles are Ghost-group parts that raycasts
	ignore, so a distance-to-segment test is used for creatures instead).

	Clients receive one "Projectile" effect at launch with the same origin, velocity
	and gravity, and draw an identical trajectory locally; the server's OnHit decides
	everything that matters.

	Dependencies: MathUtil; Registry: EnemyService, EffectService

	API:
		ProjectileSystem.Start()
		ProjectileSystem.Fire(spec) -> id
			spec = {
				Match, Origin, Velocity, Gravity?, Radius, MaxTime,
				HitEnemies: boolean, HitPlayers: boolean, IgnoreUnderground: boolean?,
				Exclude: { Instance }?,                  -- extra raycast exclusions
				Style: string, Color: Color3?,            -- client visual
				OnHit: (position, enemy?, session?) -> ()
			}
		ProjectileSystem.CancelMatch(match)
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)

type Projectile = {
	Id: number,
	Match: any,
	Origin: Vector3,
	Velocity: Vector3,
	Gravity: number,
	Radius: number,
	MaxTime: number,
	Age: number,
	Position: Vector3,
	HitEnemies: boolean,
	HitPlayers: boolean,
	IgnoreUnderground: boolean,
	Params: RaycastParams,
	OnHit: (Vector3, any?, any?) -> (),
}

local ProjectileSystem = {}

local active: { [number]: Projectile } = {}
local nextId = 0
local started = false

local function positionAt(projectile: Projectile, t: number): Vector3
	return projectile.Origin + projectile.Velocity * t + Vector3.new(0, -0.5 * projectile.Gravity * t * t, 0)
end

local function distanceToSegment(point: Vector3, a: Vector3, b: Vector3): number
	local ab = b - a
	local lengthSquared = ab:Dot(ab)
	if lengthSquared < 1e-6 then
		return (point - a).Magnitude
	end
	local t = math.clamp((point - a):Dot(ab) / lengthSquared, 0, 1)
	return (point - (a + ab * t)).Magnitude
end

local function finish(projectile: Projectile, position: Vector3, enemy: any?, session: any?)
	active[projectile.Id] = nil
	local ok, err = xpcall(projectile.OnHit, debug.traceback, position, enemy, session)
	if not ok then
		warn(`[ProjectileSystem] OnHit failed: {err}`)
	end
end

local function step(projectile: Projectile, dt: number)
	if projectile.Match.Destroyed then
		active[projectile.Id] = nil
		return
	end
	local fromPosition = projectile.Position
	local age = math.min(projectile.Age + dt, projectile.MaxTime)
	local toPosition = positionAt(projectile, age)
	projectile.Age = age
	projectile.Position = toPosition

	local segmentLength = (toPosition - fromPosition).Magnitude
	local midpoint = (fromPosition + toPosition) / 2

	-- Creatures first: they are what the shot is aimed at.
	if projectile.HitEnemies then
		local nearby = Services.EnemyService:GetEnemiesInRadius(projectile.Match, midpoint, segmentLength / 2 + projectile.Radius + 8)
		local best, bestDistance = nil, math.huge
		for _, enemy in nearby do
			if not (enemy.Underground and projectile.IgnoreUnderground) then
				local reach = projectile.Radius + enemy.HitRadius
				local distance = distanceToSegment(enemy:GetPosition(), fromPosition, toPosition)
				if distance <= reach and distance < bestDistance then
					best, bestDistance = enemy, distance
				end
			end
		end
		if best then
			finish(projectile, best:GetPosition(), best, nil)
			return
		end
	end
	if projectile.HitPlayers then
		for _, session in projectile.Match:GetLivingSessions() do
			local position = session:GetPosition()
			if position and distanceToSegment(position, fromPosition, toPosition) <= projectile.Radius + 2.5 then
				finish(projectile, position, nil, session)
				return
			end
		end
	end

	local delta = toPosition - fromPosition
	if delta.Magnitude > 1e-3 then
		local result = Workspace:Spherecast(fromPosition, projectile.Radius, delta, projectile.Params)
		if result then
			finish(projectile, result.Position, nil, nil)
			return
		end
	end

	if age >= projectile.MaxTime then
		finish(projectile, toPosition, nil, nil)
	end
end

function ProjectileSystem.Start()
	if started then
		return
	end
	started = true
	RunService.Heartbeat:Connect(function(dt)
		for _, projectile in active do
			step(projectile, dt)
		end
	end)
end

function ProjectileSystem.Fire(spec: { [string]: any }): number
	nextId += 1
	local match = spec.Match
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = { match.Folder:FindFirstChild("Enemies"), match.Folder:FindFirstChild("Crops") }
	for _, session in match:GetSessions() do
		if session.Character then
			table.insert(exclude, session.Character)
		end
	end
	for _, instance in spec.Exclude or {} do
		table.insert(exclude, instance)
	end
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true

	local projectile: Projectile = {
		Id = nextId,
		Match = match,
		Origin = spec.Origin,
		Velocity = spec.Velocity,
		Gravity = spec.Gravity or 0,
		Radius = spec.Radius or 0.5,
		MaxTime = spec.MaxTime,
		Age = 0,
		Position = spec.Origin,
		HitEnemies = spec.HitEnemies == true,
		HitPlayers = spec.HitPlayers == true,
		IgnoreUnderground = spec.IgnoreUnderground ~= false,
		Params = params,
		OnHit = spec.OnHit,
	}
	active[projectile.Id] = projectile

	Services.EffectService:PlayAt(match, "Projectile", spec.Origin, {
		Id = projectile.Id,
		Origin = spec.Origin,
		Velocity = spec.Velocity,
		Gravity = projectile.Gravity,
		MaxTime = spec.MaxTime,
		Style = spec.Style,
		Color = spec.Color,
	})
	return projectile.Id
end

function ProjectileSystem.CancelMatch(match: any)
	for id, projectile in active do
		if projectile.Match == match then
			active[id] = nil
		end
	end
end

return ProjectileSystem
