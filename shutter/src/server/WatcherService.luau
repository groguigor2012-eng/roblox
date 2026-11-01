--!strict
-- WatcherService (server): THE WATCHER's AI. "Look to survive, look away to escape."
--
-- Every think tick (THINK_RATE Hz) each Watcher asks: is ANY player filming me right now?
-- That answer is computed here, never sent by a client:
--   * CamcorderService.isFilming(player)    - server camcorder state + battery
--   * CamcorderService.getLook(player)      - server head position + fresh, validated look dir
--   * the Watcher is inside the camcorder's view cone and within VIEW_RANGE
--   * a server raycast from the head reaches the Watcher (walls block the view)
-- If yes: it FREEZES on the spot. If no: it stalks (far) or hunts (near) the closest player,
-- using PathfindingService, and catches anyone it reaches.
--
-- The model is anchored and moved with PivotTo on Heartbeat, so the server owns its
-- position completely. Clients only render it (RealityRenderer shows it while filming).

local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shutter")
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))
local CamcorderService = require(script.Parent:WaitForChild("CamcorderService"))
local WatcherRig = require(script.Parent:WaitForChild("WatcherRig"))

local W = Config.Watcher
local TAGS = Config.Tags
local ATTR = Config.Attributes

local UP = Vector3.new(0, 1, 0)
local VIEW_COS = math.cos(math.rad(W.VIEW_HALF_ANGLE))
local DIRECT_CHASE_DISTANCE = 14 -- with a clear line, walk straight at the target inside this

export type WatcherState = "Idle" | "Stalking" | "Hunting" | "Frozen" | "Cooldown"

type Watcher = {
	model: Model,
	hipHeight: number,
	height: number,
	state: WatcherState,
	target: Player?,
	path: Path,
	waypoints: { Vector3 },
	waypointIndex: number,
	computingPath: boolean,
	pathFailed: boolean,
	lastPathAt: number,
	lastPathGoal: Vector3?,
	directGoal: Vector3?,
	directAllowed: boolean,
	moveSpeed: number,
	frozenUntil: number,
	cooldownUntil: number,
	lastRelocateAt: number,
	observers: { Player },
	connections: { RBXScriptConnection },
}

type ObservedCallback = (watcherModel: Model, observers: { Player }) -> ()

local WatcherService = {}

local watchers: { [Model]: Watcher } = {}
local observedCallbacks: { ObservedCallback } = {}
local rng = Random.new()
local started = false

-- Raycast filters -----------------------------------------------------------------------------

-- View rays ignore characters, Watchers, and NakedEyeOnly parts (hidden while filming).
local viewParams = RaycastParams.new()
viewParams.FilterType = Enum.RaycastFilterType.Exclude
viewParams.IgnoreWater = true

-- Ground / clearance checks only care about solid geometry.
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true
groundParams.RespectCanCollide = true

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.RespectCanCollide = true

local lastFilterRefresh = -math.huge

local function refreshFilters(now: number)
	if now - lastFilterRefresh < 0.5 then
		return
	end
	lastFilterRefresh = now
	local dynamic: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(dynamic, player.Character)
		end
	end
	for model in watchers do
		table.insert(dynamic, model)
	end
	groundParams.FilterDescendantsInstances = dynamic
	overlapParams.FilterDescendantsInstances = dynamic

	local view = table.clone(dynamic)
	for _, hidden in CollectionService:GetTagged(TAGS.NakedEyeOnly) do
		table.insert(view, hidden)
	end
	viewParams.FilterDescendantsInstances = view
end

-- Helpers ---------------------------------------------------------------------------------------

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- True if nothing opaque lies between a and b. Near-invisible parts (glass, invisible walls)
-- are stepped through, up to a few times.
local function clearLine(a: Vector3, b: Vector3): boolean
	local from = a
	for _ = 1, 4 do
		local direction = b - from
		if direction.Magnitude < 0.05 then
			return true
		end
		local hit = workspace:Raycast(from, direction, viewParams)
		if not hit then
			return true
		end
		local instance = hit.Instance
		if instance:IsA("BasePart") and instance.Transparency >= 0.9 then
			from = hit.Position + direction.Unit * 0.05
		else
			return false
		end
	end
	return false
end

local function groundBelow(position: Vector3, depth: number): Vector3?
	local hit = workspace:Raycast(position, Vector3.new(0, -depth, 0), groundParams)
	return if hit then hit.Position else nil
end

local function feetOf(watcher: Watcher): Vector3
	return watcher.model:GetPivot().Position - UP * watcher.hipHeight
end

local function viewPointsAt(watcher: Watcher, feet: Vector3): { Vector3 }
	return {
		feet + UP * (watcher.height * 0.88), -- head
		feet + UP * (watcher.height * 0.55), -- chest
		feet + UP * (watcher.height * 0.2), -- legs (visible over low cover)
	}
end

-- Which players are filming any of `points` right now (server-side computation)?
local function observersOf(points: { Vector3 }): { Player }
	local result: { Player } = {}
	for _, player in Players:GetPlayers() do
		local origin, look = CamcorderService.getLook(player)
		if origin and look then
			for _, point in points do
				local offset = point - origin
				local distance = offset.Magnitude
				if distance > 0.05 and distance <= W.VIEW_RANGE and look:Dot(offset / distance) >= VIEW_COS then
					if clearLine(origin, point) then
						table.insert(result, player)
						break
					end
				end
			end
		end
	end
	return result
end

local function setState(watcher: Watcher, state: WatcherState)
	if watcher.state == state then
		return
	end
	watcher.state = state
	watcher.model:SetAttribute(ATTR.WatcherState, state)
	watcher.model:SetAttribute(ATTR.WatcherFrozen, state == "Frozen")
end

local function clearPath(watcher: Watcher)
	table.clear(watcher.waypoints)
	watcher.waypointIndex = 1
	watcher.lastPathGoal = nil
	watcher.directGoal = nil
	watcher.directAllowed = false
end

local function standingCFrame(watcher: Watcher, feet: Vector3, facing: Vector3): CFrame
	local pivot = feet + UP * watcher.hipHeight
	local look = flat(facing)
	if look.Magnitude < 1e-3 then
		look = flat(watcher.model:GetPivot().LookVector)
		if look.Magnitude < 1e-3 then
			look = Vector3.new(0, 0, -1)
		end
	end
	return CFrame.lookAt(pivot, pivot + look.Unit)
end

local function hasClearance(watcher: Watcher, feet: Vector3): boolean
	local size = Vector3.new(W.AGENT_RADIUS * 1.5, watcher.height - 1, W.AGENT_RADIUS * 1.5)
	local centre = CFrame.new(feet + UP * (watcher.height / 2 + 0.5))
	return #workspace:GetPartBoundsInBox(centre, size, overlapParams) == 0
end

-- Alive player root parts ------------------------------------------------------------------------

local function aliveRoot(player: Player): (BasePart?, Humanoid?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return root, humanoid
	end
	return nil, nil
end

local function pickTarget(watcher: Watcher, feet: Vector3): (Player?, BasePart?, Humanoid?, number)
	local bestPlayer: Player? = nil
	local bestRoot: BasePart? = nil
	local bestHumanoid: Humanoid? = nil
	local bestDistance = W.DETECT_RANGE
	for _, player in Players:GetPlayers() do
		local root, humanoid = aliveRoot(player)
		if root and humanoid then
			local distance = (root.Position - feet).Magnitude
			-- Hysteresis: stick with the current target unless someone is clearly closer.
			if player == watcher.target then
				distance *= 0.8
			end
			if distance < bestDistance then
				bestPlayer, bestRoot, bestHumanoid, bestDistance = player, root, humanoid, distance
			end
		end
	end
	return bestPlayer, bestRoot, bestHumanoid, bestDistance
end

-- Pathfinding -----------------------------------------------------------------------------------

local function requestPath(watcher: Watcher, goal: Vector3, now: number)
	if watcher.computingPath then
		return
	end
	watcher.computingPath = true
	watcher.lastPathAt = now
	watcher.lastPathGoal = goal
	local start = feetOf(watcher) + UP
	task.spawn(function()
		local ok = pcall(function()
			watcher.path:ComputeAsync(start, goal)
		end)
		watcher.computingPath = false
		if not watcher.model.Parent then
			return
		end
		if ok and watcher.path.Status == Enum.PathStatus.Success then
			local points: { Vector3 } = {}
			for _, waypoint in watcher.path:GetWaypoints() do
				table.insert(points, waypoint.Position)
			end
			watcher.waypoints = points
			watcher.waypointIndex = 2 -- the first waypoint is where we already stand
			watcher.pathFailed = false
		else
			table.clear(watcher.waypoints)
			watcher.waypointIndex = 1
			watcher.pathFailed = true
		end
	end)
end

-- Relocation & respawn --------------------------------------------------------------------------

local function spawnPoints(): { Vector3 }
	local points: { Vector3 } = {}
	for _, marker in CollectionService:GetTagged(TAGS.WatcherSpawn) do
		if marker:IsA("BasePart") then
			table.insert(points, marker.Position)
		elseif marker:IsA("Model") then
			table.insert(points, marker:GetPivot().Position)
		end
	end
	if #points == 0 then
		local spawnLocation = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
		local base = if spawnLocation then spawnLocation.Position else Vector3.new(0, 4, 0)
		table.insert(points, base + W.FALLBACK_SPAWN_OFFSET)
	end
	return points
end

local function placeOnGround(position: Vector3): Vector3
	local ground = groundBelow(position + UP * 4, 80)
	return ground or position
end

-- Teleport behind the target, somewhere no camcorder is currently pointed.
local function tryRelocate(watcher: Watcher, targetRoot: BasePart, now: number): boolean
	local behind = -flat(targetRoot.CFrame.LookVector)
	if behind.Magnitude < 1e-3 then
		behind = Vector3.new(0, 0, 1)
	end
	behind = behind.Unit
	for _ = 1, 8 do
		local angle = math.rad(rng:NextNumber(-70, 70))
		local direction = CFrame.Angles(0, angle, 0):VectorToWorldSpace(behind)
		local candidate = targetRoot.Position + direction * rng:NextNumber(W.RELOCATE_MIN, W.RELOCATE_MAX)
		local ground = groundBelow(candidate + UP * 3, 30)
		if ground and hasClearance(watcher, ground) and #observersOf(viewPointsAt(watcher, ground)) == 0 then
			watcher.model:PivotTo(standingCFrame(watcher, ground, targetRoot.Position - ground))
			watcher.lastRelocateAt = now
			clearPath(watcher)
			return true
		end
	end
	watcher.lastRelocateAt = now - W.RELOCATE_COOLDOWN * 0.5 -- retry sooner
	return false
end

local function respawnFar(watcher: Watcher)
	local points = spawnPoints()
	local best = points[1]
	local bestScore = -math.huge
	for _, point in points do
		-- Prefer the spawn farthest from the nearest living player.
		local nearest = math.huge
		for _, player in Players:GetPlayers() do
			local root = aliveRoot(player)
			if root then
				nearest = math.min(nearest, (root.Position - point).Magnitude)
			end
		end
		if nearest > bestScore then
			best, bestScore = point, nearest
		end
	end
	local feet = placeOnGround(best)
	watcher.model:PivotTo(standingCFrame(watcher, feet, watcher.model:GetPivot().LookVector))
	clearPath(watcher)
end

-- Catching ----------------------------------------------------------------------------------------

local function catch(watcher: Watcher, player: Player, humanoid: Humanoid, now: number)
	watcher.cooldownUntil = now + W.COOLDOWN_AFTER_CATCH
	watcher.target = nil
	clearPath(watcher)
	setState(watcher, "Cooldown")
	CamcorderService.forceLower(player, "caught")
	Net.WatcherFeedback:FireClient(player, "Caught", watcher.model)
	task.delay(0.35, function()
		if humanoid.Parent and humanoid.Health > 0 then
			humanoid:TakeDamage(W.CATCH_DAMAGE)
		end
	end)
	task.delay(W.COOLDOWN_AFTER_CATCH * 0.6, function()
		if watcher.model.Parent then
			respawnFar(watcher)
		end
	end)
end

-- Think (THINK_RATE Hz) ------------------------------------------------------------------------------

local function think(watcher: Watcher, now: number)
	local feet = feetOf(watcher)
	local observers = observersOf(viewPointsAt(watcher, feet))
	watcher.observers = observers
	if #observers > 0 then
		watcher.frozenUntil = now + W.MIN_FREEZE_HOLD
		for _, callback in observedCallbacks do
			task.spawn(callback, watcher.model, observers)
		end
	end

	if now < watcher.frozenUntil then
		setState(watcher, "Frozen")
		return
	end
	if now < watcher.cooldownUntil then
		setState(watcher, "Cooldown")
		return
	end

	local target, root, humanoid, distance = pickTarget(watcher, feet)
	if not target or not root or not humanoid then
		watcher.target = nil
		clearPath(watcher)
		setState(watcher, "Idle")
		return
	end
	if target ~= watcher.target then
		watcher.target = target
		clearPath(watcher)
	end

	-- Catch?
	local offset = root.Position - feet
	local verticalGap = math.abs(root.Position.Y - (feet.Y + watcher.hipHeight))
	if flat(offset).Magnitude <= W.CATCH_RANGE and verticalGap <= W.CATCH_HEIGHT then
		catch(watcher, target, humanoid, now)
		return
	end

	-- Too far behind? Reappear somewhere behind them, out of every camcorder's view.
	if distance > W.RELOCATE_DISTANCE and now - watcher.lastRelocateAt > W.RELOCATE_COOLDOWN then
		if tryRelocate(watcher, root, now) then
			return
		end
	end

	local hunting = distance <= W.HUNT_RANGE
	setState(watcher, if hunting then "Hunting" else "Stalking")
	watcher.moveSpeed = if hunting then W.HUNT_SPEED else W.STALK_SPEED

	local goal = groundBelow(root.Position, 12) or (root.Position - UP * (humanoid.HipHeight + root.Size.Y / 2))
	watcher.directGoal = goal
	local chest = feet + UP * (watcher.height * 0.55)
	local closeEnough = distance <= DIRECT_CHASE_DISTANCE or watcher.pathFailed
	watcher.directAllowed = closeEnough and clearLine(chest, root.Position)

	local lastGoal = watcher.lastPathGoal
	if
		not lastGoal
		or (goal - lastGoal).Magnitude > W.PATH_REPATH_DISTANCE
		or now - watcher.lastPathAt > W.PATH_REFRESH
	then
		requestPath(watcher, goal, now)
	end
end

-- Move (every Heartbeat) ---------------------------------------------------------------------------

local function move(watcher: Watcher, dt: number)
	if watcher.state ~= "Stalking" and watcher.state ~= "Hunting" then
		return
	end
	local feet = feetOf(watcher)
	local destination: Vector3? = nil
	local direct = false

	if watcher.directAllowed and watcher.directGoal then
		destination = watcher.directGoal
		direct = true
	else
		while watcher.waypointIndex <= #watcher.waypoints do
			local waypoint = watcher.waypoints[watcher.waypointIndex]
			if flat(waypoint - feet).Magnitude < 0.75 and math.abs(waypoint.Y - feet.Y) < 3 then
				watcher.waypointIndex += 1
			else
				destination = waypoint
				break
			end
		end
	end
	if not destination then
		return
	end

	local delta = destination - feet
	local length = delta.Magnitude
	if length < 1e-3 then
		return
	end
	local stepLength = watcher.moveSpeed * dt
	local nextFeet = if length <= stepLength then destination else feet + delta / length * stepLength
	if direct then
		local ground = groundBelow(nextFeet + UP * 3, 8)
		if ground then
			nextFeet = ground
		end
	end
	watcher.model:PivotTo(standingCFrame(watcher, nextFeet, delta))
end

-- Registration -----------------------------------------------------------------------------------

local function register(model: Instance)
	if not model:IsA("Model") or watchers[model] then
		return
	end
	if not model:IsDescendantOf(workspace) then
		return
	end
	if not model.PrimaryPart then
		local first = model:FindFirstChildWhichIsA("BasePart", true)
		if not first then
			warn(`[Shutter] Watcher {model:GetFullName()} has no parts; ignoring it`)
			return
		end
		model.PrimaryPart = first
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CastShadow = false
		elseif descendant:IsA("Humanoid") then
			warn(`[Shutter] Watcher {model:GetFullName()} contains a Humanoid; it is not needed and was removed`)
			descendant:Destroy()
		end
	end
	-- The Watcher is only ever seen through the camcorder.
	if not CollectionService:HasTag(model, TAGS.CameraOnly) then
		CollectionService:AddTag(model, TAGS.CameraOnly)
	end

	local boxCFrame, boxSize = model:GetBoundingBox()
	local bottom = boxCFrame.Position.Y - boxSize.Y / 2
	local pivot = model:GetPivot()
	local watcher: Watcher = {
		model = model,
		hipHeight = math.max(0.5, pivot.Position.Y - bottom),
		height = boxSize.Y,
		state = "Idle",
		target = nil,
		path = PathfindingService:CreatePath({
			AgentRadius = W.AGENT_RADIUS,
			AgentHeight = W.AGENT_HEIGHT,
			AgentCanJump = false,
			AgentCanClimb = false,
			WaypointSpacing = 4,
		}),
		waypoints = {},
		waypointIndex = 1,
		computingPath = false,
		pathFailed = false,
		lastPathAt = -math.huge,
		lastPathGoal = nil,
		directGoal = nil,
		directAllowed = false,
		moveSpeed = W.STALK_SPEED,
		frozenUntil = 0,
		cooldownUntil = 0,
		lastRelocateAt = os.clock(),
		observers = {},
		connections = {},
	}
	model:SetAttribute(ATTR.WatcherState, "Idle")
	model:SetAttribute(ATTR.WatcherFrozen, false)
	watchers[model] = watcher
	lastFilterRefresh = -math.huge

	table.insert(
		watcher.connections,
		model.AncestryChanged:Connect(function()
			if not model:IsDescendantOf(workspace) then
				local entry = watchers[model]
				if entry then
					for _, connection in entry.connections do
						connection:Disconnect()
					end
					watchers[model] = nil
				end
			end
		end)
	)
end

local function unregister(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local entry = watchers[model]
	if entry then
		for _, connection in entry.connections do
			connection:Disconnect()
		end
		watchers[model] = nil
	end
end

local function spawnDefaultWatcher()
	local points = spawnPoints()
	local feet = placeOnGround(points[1])
	local model = WatcherRig.build(feet, nil)
	model.Parent = workspace -- the Entity tag registers it
end

-- Public API -------------------------------------------------------------------------------------

function WatcherService.start()
	if started then
		return
	end
	started = true

	CollectionService:GetInstanceAddedSignal(TAGS.Entity):Connect(register)
	CollectionService:GetInstanceRemovedSignal(TAGS.Entity):Connect(unregister)
	for _, model in CollectionService:GetTagged(TAGS.Entity) do
		register(model)
	end
	if next(watchers) == nil and W.AUTO_SPAWN_IF_MISSING then
		spawnDefaultWatcher()
	end

	local interval = 1 / W.THINK_RATE
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator >= interval then
			accumulator = math.min(accumulator - interval, interval)
			local now = os.clock()
			refreshFilters(now)
			for _, watcher in watchers do
				think(watcher, now)
			end
		end
		for _, watcher in watchers do
			move(watcher, dt)
		end
	end)
end

-- Players currently freezing this Watcher (empty table when it is free to move).
function WatcherService.getObservers(model: Model): { Player }
	local watcher = watchers[model]
	return if watcher then table.clone(watcher.observers) else {}
end

function WatcherService.getState(model: Model): WatcherState?
	local watcher = watchers[model]
	return if watcher then watcher.state else nil
end

function WatcherService.getWatchers(): { Model }
	local list: { Model } = {}
	for model in watchers do
		table.insert(list, model)
	end
	return list
end

-- Fires every think tick while at least one player is filming the Watcher.
function WatcherService.onObserved(callback: ObservedCallback): () -> ()
	table.insert(observedCallbacks, callback)
	return function()
		local index = table.find(observedCallbacks, callback)
		if index then
			table.remove(observedCallbacks, index)
		end
	end
end

return WatcherService
