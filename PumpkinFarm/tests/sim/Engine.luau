--[[
	Server simulation engine.

	Boots the real server (ServerScriptService.Server.Bootstrap and every service,
	unmodified) inside an emulated DataModel, with:
	  * virtual time (tests/sim/Scheduler) driving task.*, os.clock and Heartbeat
	  * Workspace spatial queries (tests/sim/Geometry)
	  * simple physics: Humanoid:MoveTo walking with collision against solid parts and
	    ground snapping, AlignPosition movers, ballistic flight while PlatformStand,
	    Humanoid.Died when health reaches zero
	  * a grid A* stand-in for PathfindingService (the game's own UndergroundRouter A*,
	    probing for tall solid obstacles instead of soil)
	  * fake players with LoadCharacter, Backpack and chat, and direct remote plumbing:
	    sim:Invoke / sim:Fire call the server handlers; FireClient payloads are recorded

	Everything gameplay-relevant (services, AI, match flow, data) is production code.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local Geometry = require("./Geometry")
local Scheduler = require("./Scheduler")

local Instance, Vector3, CFrame, Enum = roblox.Instance, roblox.Vector3, roblox.CFrame, roblox.Enum

local FRAME = 1 / 20

-- Lune cannot read BasePart.Position (the engine derives it from CFrame), so reads of
-- `<identifier chain>.Position` are rewritten to `__P(<chain>)` at load time. Writes
-- (`x.Position = v`, `x.Position += v`) are left untouched.
local function rewritePositionReads(source: string): string
	local out = {}
	local index = 1
	while true do
		local first, last, expression = source:find("([%a_][%w_%.]*)%.Position", index)
		if first == nil then
			table.insert(out, source:sub(index))
			break
		end
		local following = source:sub(last + 1)
		local continuesIdentifier = following:match("^[%w_]") ~= nil
		local isAssignment = following:match("^%s*=[^=]") ~= nil or following:match("^%s*[%+%-%*/]=") ~= nil
		local previous = if first > 1 then source:sub(first - 1, first - 1) else ""
		if continuesIdentifier or isAssignment or previous == ":" or previous == "." then
			table.insert(out, source:sub(index, last))
		else
			table.insert(out, source:sub(index, first - 1))
			table.insert(out, "__P(" .. expression .. ")")
		end
		index = last + 1
	end
	return table.concat(out)
end

-- Lune's Instance:Destroy frees the instance, after which any property read panics;
-- Roblox keeps destroyed instances readable (Parent = nil). Calls and lookups of the
-- exact identifier `Destroy` are renamed to `__SimDestroy`, which detaches instances the
-- way the engine does and is also defined on the simulator's own Lua objects.
local function renameDestroy(source: string): string
	return (source:gsub("([%.:])Destroy([^%w_])", "%1__SimDestroy%2"))
end

local function readPosition(value)
	if typeof(value) == "Instance" and value:IsA("BasePart") then
		return value.CFrame.Position
	end
	return value.Position
end

-- Engine defaults for properties Lune's emulation leaves unset.
local function applyDefaults(instance)
	if instance:IsA("BasePart") then
		instance.AssemblyLinearVelocity = Vector3.zero
	elseif instance:IsA("Humanoid") then
		instance.MaxHealth = 100
		instance.Health = 100
		instance.PlatformStand = false
		instance.Jump = false
	end
end

local Engine = {}
Engine.__index = Engine

-- Signals ------------------------------------------------------------------------------

local function newSignal(scheduler)
	local signal = { _connections = {} }
	function signal:Connect(fn)
		local connection = { Connected = true }
		function connection:Disconnect()
			connection.Connected = false
		end
		table.insert(signal._connections, { Connection = connection, Fn = fn })
		return connection
	end
	function signal:Once(fn)
		local connection
		connection = signal:Connect(function(...)
			connection:Disconnect()
			fn(...)
		end)
		return connection
	end
	function signal:Fire(...)
		for _, entry in table.clone(signal._connections) do
			if entry.Connection.Connected then
				scheduler:Spawn(entry.Fn, ...)
			end
		end
	end
	function signal:Wait()
		local thread = coroutine.running()
		signal:Once(function(...)
			scheduler:Spawn(thread, ...)
		end)
		return coroutine.yield()
	end
	return signal
end

-- Random polyfill (Roblox's Random is engine-only).
local RandomClass = {}
RandomClass.__index = RandomClass
function RandomClass.new(seed)
	local state = math.floor(seed or 12345) % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	return setmetatable({ _state = state }, RandomClass)
end
function RandomClass:_next()
	self._state = (self._state * 48271) % 2147483647
	return self._state
end
function RandomClass:NextNumber(min, max)
	local unit = (self:_next() - 1) / 2147483646
	if min and max then
		return min + (max - min) * unit
	end
	return unit
end
function RandomClass:NextInteger(min, max)
	return min + (self:_next() % (max - min + 1))
end

local function permissiveStub(name)
	return setmetatable({}, {
		__index = function(_, key)
			return permissiveStub(name .. "." .. tostring(key))
		end,
		__call = function()
			return permissiveStub(name .. "()")
		end,
	})
end

-- Engine ---------------------------------------------------------------------------------

function Engine.new(options)
	options = options or {}
	local self = setmetatable({}, Engine)
	self.Scheduler = Scheduler.new()
	self.DataModel = Instance.new("DataModel")
	self.Workspace = self.DataModel:GetService("Workspace")
	self.Geometry = Geometry.new(self.Workspace)
	self.Warnings = {} :: { string }
	self.Prints = {} :: { string }
	self.ClientEvents = {} :: { [any]: { { Name: string, Args: { any } } } }
	self.Players = {} :: { any }
	self.AllPlayers = {} :: { any }
	self.Heartbeat = newSignal(self.Scheduler)
	self.Echo = options.Echo == true
	self._modulePaths = {}
	self._sources = {}
	self._moduleCache = {}
	self._signals = setmetatable({}, { __mode = "k" })
	self._invokeHandlers = setmetatable({}, { __mode = "k" })
	self._moveTargets = setmetatable({}, { __mode = "k" })
	self._humanoids = setmetatable({}, { __mode = "k" })
	self._playerHumanoids = setmetatable({}, { __mode = "k" })
	self._aligners = setmetatable({}, { __mode = "k" })
	self._died = setmetatable({}, { __mode = "k" })
	self._planners = {}
	self._mapBounds = {}
	self._mapKey = nil
	self._bindToClose = {}
	self:_installShims()
	self:_buildServices()
	self:_mountTree()
	return self
end

function Engine:_signalFor(instance, name)
	local perInstance = self._signals[instance]
	if perInstance == nil then
		perInstance = {}
		self._signals[instance] = perInstance
	end
	local signal = perInstance[name]
	if signal == nil then
		signal = newSignal(self.Scheduler)
		perInstance[name] = signal
	end
	return signal
end

-- Lune registers shims per class for the whole process, so they are installed once and
-- dispatch to the engine that is currently running.
local current = nil
local shimsInstalled = false

function Engine:_installShims()
	current = self
	if shimsInstalled then
		return
	end
	shimsInstalled = true
	local engine = setmetatable({}, {
		__index = function(_, key)
			return current[key]
		end,
	})
	local function event(className, name)
		roblox.implementProperty(className, name, function(instance)
			return engine:_signalFor(instance, name)
		end)
	end
	for _, name in { "ChildAdded", "ChildRemoved", "DescendantAdded", "DescendantRemoving", "AncestryChanged", "Destroying" } do
		event("Instance", name)
	end
	event("Humanoid", "Died")
	event("Humanoid", "HealthChanged")
	event("ProximityPrompt", "Triggered")
	event("RemoteEvent", "OnServerEvent")
	event("BasePart", "Touched")

	roblox.implementMethod("Instance", "WaitForChild", function(instance, name)
		return instance:FindFirstChild(name)
	end)
	roblox.implementMethod("Instance", "GetAttributeChangedSignal", function(instance, name)
		return engine:_signalFor(instance, "Attribute:" .. name)
	end)

	local function pivotOf(model)
		if model.PrimaryPart then
			return model.PrimaryPart.CFrame
		end
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				return descendant.CFrame
			end
		end
		return CFrame.new()
	end
	roblox.implementMethod("Model", "GetPivot", pivotOf)
	roblox.implementMethod("Model", "PivotTo", function(model, target)
		local delta = target * pivotOf(model):Inverse()
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.CFrame = delta * descendant.CFrame
			end
		end
	end)
	roblox.implementMethod("Model", "GetExtentsSize", function(model)
		local min, max
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				local half = descendant.Size / 2
				local position = descendant.CFrame.Position
				min = if min then min:Min(position - half) else position - half
				max = if max then max:Max(position + half) else position + half
			end
		end
		return if min then max - min else Vector3.zero
	end)
	roblox.implementMethod("Model", "ScaleTo", function() end)
	roblox.implementMethod("BasePart", "SetNetworkOwner", function() end)
	roblox.implementMethod("Instance", "__SimDestroy", function(instance)
		instance.Parent = nil
	end)

	roblox.implementMethod("Humanoid", "MoveTo", function(humanoid, position)
		engine._moveTargets[humanoid] = position
	end)
	roblox.implementMethod("Humanoid", "SetStateEnabled", function() end)
	roblox.implementMethod("Humanoid", "ChangeState", function() end)
	roblox.implementMethod("Humanoid", "EquipTool", function(humanoid, tool)
		tool.Parent = humanoid.Parent
	end)
	roblox.implementMethod("Humanoid", "UnequipTools", function(humanoid)
		local character = humanoid.Parent
		for _, player in engine.Players do
			if player.Character == character then
				for _, child in character:GetChildren() do
					if child:IsA("Tool") then
						child.Parent = player.Backpack
					end
				end
			end
		end
	end)

	roblox.implementMethod("RemoteEvent", "FireClient", function(remote, player, ...)
		engine:_recordClientEvent(player, remote.Name, table.pack(...))
	end)
	roblox.implementMethod("RemoteEvent", "FireAllClients", function(remote, ...)
		for _, player in engine.Players do
			engine:_recordClientEvent(player, remote.Name, table.pack(...))
		end
	end)
	roblox.implementProperty("RemoteFunction", "OnServerInvoke", function(remote)
		return engine._invokeHandlers[remote]
	end, function(remote, handler)
		engine._invokeHandlers[remote] = handler
	end)

	roblox.implementMethod("Workspace", "GetServerTimeNow", function()
		return 1_700_000_000 + engine.Scheduler.Now
	end)
	roblox.implementMethod("Workspace", "Raycast", function(_, origin, direction, params)
		return engine.Geometry:Raycast(origin, direction, params)
	end)
	roblox.implementMethod("Workspace", "Spherecast", function(_, origin, _radius, direction, params)
		return engine.Geometry:Raycast(origin, direction, params)
	end)
	roblox.implementMethod("Workspace", "GetPartBoundsInBox", function(_, cframe, size, params)
		return engine.Geometry:GetPartBoundsInBox(cframe, size, params)
	end)
end

function Engine:_recordClientEvent(player, name, args)
	local list = self.ClientEvents[player]
	if list == nil then
		list = {}
		self.ClientEvents[player] = list
	end
	table.insert(list, { Name = name, Args = args })
end

-- Services -----------------------------------------------------------------------------------

function Engine:_buildServices()
	local engine = self
	local scheduler = self.Scheduler
	local players = {
		PlayerAdded = newSignal(scheduler),
		PlayerRemoving = newSignal(scheduler),
		CharacterAutoLoads = true,
	}
	function players:GetPlayers()
		return table.clone(engine.Players)
	end
	function players:GetPlayerByUserId(userId)
		for _, player in engine.Players do
			if player.UserId == userId then
				return player
			end
		end
		return nil
	end
	self.PlayersService = players

	local runService = { Heartbeat = self.Heartbeat, Stepped = self.Heartbeat, RenderStepped = self.Heartbeat }
	function runService:IsStudio()
		return true
	end
	function runService:IsServer()
		return true
	end

	local pathfinding = {}
	function pathfinding:CreatePath(agent)
		return engine:_createPath(agent)
	end

	local debris = {}
	function debris:AddItem(instance, lifetime)
		scheduler:Delay(lifetime or 10, function()
			instance.Parent = nil
		end)
	end

	local http = {}
	local guid = 0
	function http:GenerateGUID()
		guid += 1
		return string.format("00000000-0000-0000-0000-%012d", guid)
	end
	function http:JSONEncode(value)
		return serde.encode("json", value)
	end
	function http:JSONDecode(value)
		return serde.decode("json", value)
	end

	local physics = permissiveStub("PhysicsService")
	local textChat = { ChatVersion = Enum.ChatVersion.LegacyChatService }

	self._serviceOverrides = {
		Players = players,
		RunService = runService,
		PathfindingService = pathfinding,
		Debris = debris,
		HttpService = http,
		PhysicsService = physics,
		TextChatService = textChat,
		DataStoreService = permissiveStub("DataStoreService"),
		TweenService = permissiveStub("TweenService"),
		ProximityPromptService = permissiveStub("ProximityPromptService"),
		UserInputService = permissiveStub("UserInputService"),
		ContextActionService = permissiveStub("ContextActionService"),
	}

	local dataModel = self.DataModel
	self.Game = setmetatable({ PlaceId = 0, JobId = "" }, {
		__index = function(_, key)
			if key == "GetService" then
				return function(_, name)
					return engine._serviceOverrides[name] or dataModel:GetService(name)
				end
			elseif key == "BindToClose" then
				return function(_, fn)
					table.insert(engine._bindToClose, fn)
				end
			end
			return nil
		end,
	})
end

-- Module tree / loader --------------------------------------------------------------------------

function Engine:_mount(parent, directory)
	for _, entry in fs.readDir(directory) do
		local full = directory .. "/" .. entry
		local instance
		if fs.isDir(full) then
			instance = Instance.new("Folder")
			instance.Name = entry
			instance.Parent = parent
			self:_mount(instance, full)
		elseif entry:match("%.server%.luau$") then
			instance = Instance.new("Script")
			instance.Name = entry:gsub("%.server%.luau$", "")
		elseif entry:match("%.client%.luau$") then
			instance = Instance.new("LocalScript")
			instance.Name = entry:gsub("%.client%.luau$", "")
		elseif entry:match("%.luau$") then
			instance = Instance.new("ModuleScript")
			instance.Name = entry:gsub("%.luau$", "")
		end
		if instance and not fs.isDir(full) then
			self._modulePaths[instance] = full
			-- Read now, on the main thread: Lune's fs is async and would yield a
			-- simulated coroutine that Lune's own scheduler does not own.
			self._sources[instance] = fs.readFile(full)
			instance.Parent = parent
		end
	end
end

function Engine:_mountTree()
	local dm = self.DataModel
	local shared = Instance.new("Folder")
	shared.Name = "Shared"
	shared.Parent = dm:GetService("ReplicatedStorage")
	self:_mount(shared, "src/shared")
	local assets = Instance.new("Folder")
	assets.Name = "Assets"
	assets.Parent = dm:GetService("ReplicatedStorage")
	local server = Instance.new("Folder")
	server.Name = "Server"
	server.Parent = dm:GetService("ServerScriptService")
	self:_mount(server, "src/server")
	for _, name in { "Packages", "Maps" } do
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = dm:GetService("ServerStorage")
	end
	self.ServerRoot = server
end

function Engine:_env(scriptInstance)
	local engine = self
	local instanceLibrary = {
		new = function(className)
			if className == "BindableEvent" then
				local signal = newSignal(engine.Scheduler)
				return {
					Event = signal,
					Fire = function(_, ...)
						signal:Fire(...)
					end,
					__SimDestroy = function() end,
				}
			end
			local instance = Instance.new(className)
			applyDefaults(instance)
			if className == "Humanoid" then
				engine._humanoids[instance] = true
			elseif className == "AlignPosition" then
				engine._aligners[instance] = true
			end
			return instance
		end,
	}
	return {
		script = scriptInstance,
		game = self.Game,
		workspace = self.Workspace,
		require = function(module)
			return engine:Require(module)
		end,
		task = self.Scheduler:CreateTaskLibrary(),
		os = self.Scheduler:CreateOsLibrary(),
		Random = RandomClass,
		Instance = instanceLibrary,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		ColorSequence = roblox.ColorSequence,
		NumberSequence = roblox.NumberSequence,
		NumberRange = roblox.NumberRange,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Enum = roblox.Enum,
		__P = readPosition,
		RaycastParams = { new = function() return {} end },
		OverlapParams = { new = function() return {} end },
		TweenInfo = { new = function() return {} end },
		warn = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring((select(i, ...))))
			end
			local message = table.concat(parts, " ")
			table.insert(engine.Warnings, message)
			if engine.Echo then
				print("[warn] " .. message)
			end
		end,
		print = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring((select(i, ...))))
			end
			table.insert(engine.Prints, table.concat(parts, " "))
		end,
	}
end

function Engine:_load(scriptInstance)
	local path = self._modulePaths[scriptInstance]
	assert(path, `[sim] {scriptInstance:GetFullName()} is not a mounted script`)
	local source = renameDestroy(rewritePositionReads(self._sources[scriptInstance]))
	return luau.load(source, { debugName = path, environment = self:_env(scriptInstance) })
end

function Engine:Require(module)
	local cached = self._moduleCache[module]
	if cached ~= nil then
		return cached
	end
	local result = self:_load(module)()
	self._moduleCache[module] = result
	return result
end

-- "Services.MatchService" / "Systems.MapBuilder" relative to ServerScriptService.Server
function Engine:RequireServer(path)
	local node = self.ServerRoot
	for _, part in string.split(path, ".") do
		node = node:FindFirstChild(part)
		assert(node, `[sim] missing {path}`)
	end
	return self:Require(node)
end

function Engine:Service(name)
	return self:RequireServer("Registry")[name]
end

-- Pathfinding stand-in ----------------------------------------------------------------------------

-- Arena lookup by position. Bounds are cached and rebuilt when the set of match folders
-- changes, so the per-frame physics does only number comparisons.
function Engine:_refreshMapBounds()
	local matches = self.Workspace:FindFirstChild("Matches")
	local children = if matches then matches:GetChildren() else {}
	local key = #children
	for _, child in children do
		key ..= ":" .. child.Name
	end
	if key == self._mapKey then
		return
	end
	self._mapKey = key
	local bounds = {}
	for _, match in children do
		local map = match:FindFirstChild("Map")
		local ground = map and map:FindFirstChild("Ground")
		local floor = ground and ground:FindFirstChild("Floor")
		if floor then
			local center, size = floor.CFrame.Position, floor.Size
			table.insert(bounds, {
				Map = map,
				Floor = floor,
				MinX = center.X - size.X / 2,
				MaxX = center.X + size.X / 2,
				MinZ = center.Z - size.Z / 2,
				MaxZ = center.Z + size.Z / 2,
			})
		end
	end
	self._mapBounds = bounds
end

function Engine:_mapFor(position)
	if self._mapFrame ~= self.Frame then
		self._mapFrame = self.Frame
		self:_refreshMapBounds()
	end
	for _, entry in self._mapBounds do
		if position.X >= entry.MinX and position.X <= entry.MaxX and position.Z >= entry.MinZ and position.Z <= entry.MaxZ then
			return entry.Map, entry.Floor
		end
	end
	return nil, nil
end

function Engine:_planner(map, floor)
	local planner = self._planners[map]
	if planner then
		return planner
	end
	local Router = self:RequireServer("AI.UndergroundRouter")
	local geometry = self.Geometry
	local center, size = floor.CFrame.Position, floor.Size
	local floorY = center.Y + size.Y / 2
	planner = Router.new({
		MinX = center.X - size.X / 2 + 4,
		MinZ = center.Z - size.Z / 2 + 4,
		MaxX = center.X + size.X / 2 - 4,
		MaxZ = center.Z + size.Z / 2 - 4,
		FloorY = floorY,
		CellSize = 4,
		MaxExpansions = 40000,
		Probe = function(x, z)
			return geometry:CellWalkable(map, x, z, 2, floorY)
		end,
	})
	self._planners[map] = planner
	return planner
end

function Engine:_createPath(_agent)
	local engine = self
	local path = { Status = Enum.PathStatus.NoPath, _waypoints = {} }
	function path:ComputeAsync(from, to)
		engine.Scheduler:Wait(0.05)
		local map, floor = engine:_mapFor(to)
		if map == nil then
			path.Status = Enum.PathStatus.NoPath
			return
		end
		local points = engine:_planner(map, floor):FindPath(from, to)
		if points == nil then
			path.Status = Enum.PathStatus.NoPath
			path._waypoints = {}
			return
		end
		local waypoints = { { Position = from, Action = Enum.PathWaypointAction.Walk, Label = "" } }
		for _, point in points do
			table.insert(waypoints, { Position = point, Action = Enum.PathWaypointAction.Walk, Label = "" })
		end
		table.insert(waypoints, { Position = to, Action = Enum.PathWaypointAction.Walk, Label = "" })
		path._waypoints = waypoints
		path.Status = Enum.PathStatus.Success
	end
	function path:GetWaypoints()
		return path._waypoints
	end
	function path:__SimDestroy() end
	return path
end

-- Players ----------------------------------------------------------------------------------------------

function Engine:AddPlayer(name)
	local engine = self
	local userId = 1000 + #self.Players + 1
	local attributes = {}
	local backpack = Instance.new("Backpack")
	local player = {
		Name = name,
		DisplayName = name,
		UserId = userId,
		Parent = self.PlayersService,
		Character = nil,
		Backpack = backpack,
		Chatted = newSignal(self.Scheduler),
		Kicked = nil,
	}
	function player:SetAttribute(key, value)
		attributes[key] = value
	end
	function player:GetAttribute(key)
		return attributes[key]
	end
	function player:GetAttributeChangedSignal(key)
		return engine:_signalFor(backpack, "PlayerAttribute:" .. key)
	end
	function player:FindFirstChildOfClass(className)
		return if className == "Backpack" then backpack else nil
	end
	function player:Kick(message)
		player.Kicked = message or "kicked"
	end
	function player:LoadCharacter()
		if player.Character then
			player.Character.Parent = nil
		end
		local character = Instance.new("Model")
		character.Name = name
		local root = Instance.new("Part")
		applyDefaults(root)
		root.Name = "HumanoidRootPart"
		root.Size = Vector3.new(2, 2, 1)
		root.Anchored = false
		root.Parent = character
		local head = Instance.new("Part")
		head.Name = "Head"
		head.Size = Vector3.new(1.2, 1.2, 1.2)
		head.CFrame = CFrame.new(0, 1.6, 0)
		head.Parent = character
		local humanoid = Instance.new("Humanoid")
		applyDefaults(humanoid)
		humanoid.HipHeight = 2
		humanoid.MaxHealth = 100
		humanoid.Health = 100
		humanoid.WalkSpeed = 16
		humanoid.Parent = character
		engine._humanoids[humanoid] = true
		engine._playerHumanoids[humanoid] = true
		local colors = Instance.new("BodyColors")
		colors.Parent = character
		character.PrimaryPart = root
		character:PivotTo(CFrame.new(0, 4, 12))
		character.Parent = engine.Workspace
		player.Character = character
	end
	table.insert(self.Players, player)
	table.insert(self.AllPlayers, player)
	self.PlayersService.PlayerAdded:Fire(player)
	return player
end

function Engine:RemovePlayer(player)
	self.PlayersService.PlayerRemoving:Fire(player)
	local index = table.find(self.Players, player)
	if index then
		table.remove(self.Players, index)
	end
	player.Parent = nil
	if player.Character then
		player.Character.Parent = nil
		player.Character = nil
	end
end

function Engine:Teleport(player, position)
	local character = player.Character
	if character then
		character:PivotTo(CFrame.new(position))
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			self._moveTargets[humanoid] = nil
		end
	end
end

-- Remotes ------------------------------------------------------------------------------------------------

function Engine:_remote(name)
	local remotes = self.DataModel:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
	local remote = remotes and remotes:FindFirstChild(name)
	assert(remote, `[sim] remote {name} not found`)
	return remote
end

function Engine:Invoke(player, name, ...)
	local handler = self._invokeHandlers[self:_remote(name)]
	assert(handler, `[sim] no OnServerInvoke for {name}`)
	local args = table.pack(...)
	local done, result = false, nil
	self.Scheduler:Spawn(function()
		result = handler(player, table.unpack(args, 1, args.n))
		done = true
	end)
	local guard = 0
	while not done and guard < 400 do
		self:Step(FRAME)
		guard += 1
	end
	assert(done, `[sim] {name} never returned`)
	return result
end

function Engine:Fire(player, name, ...)
	self:_remote(name).OnServerEvent:Fire(player, ...)
end

function Engine:Chat(player, text)
	player.Chatted:Fire(text)
end

function Engine:LastEvent(player, name)
	local list = self.ClientEvents[player] or {}
	for index = #list, 1, -1 do
		if list[index].Name == name then
			return list[index].Args
		end
	end
	return nil
end

function Engine:CountEvents(player, name, predicate)
	local count = 0
	for _, event in self.ClientEvents[player] or {} do
		if event.Name == name and (predicate == nil or predicate(table.unpack(event.Args, 1, event.Args.n))) then
			count += 1
		end
	end
	return count
end

-- Physics ------------------------------------------------------------------------------------------------

local function moveModel(model, root, newPosition, facing)
	local look = if facing and facing.Magnitude > 0.01 then CFrame.lookAt(newPosition, newPosition + facing) else root.CFrame.Rotation + newPosition
	model:PivotTo(look)
end

function Engine:_physics(dt)
	local workspace = self.Workspace
	local gravity = workspace.Gravity
	local driven = {}

	for aligner in self._aligners do
		local attachment = aligner.Attachment0
		local root = attachment and attachment.Parent
		if aligner.Enabled and root and root:IsDescendantOf(workspace) then
			driven[root] = true
			local model = root:FindFirstAncestorWhichIsA("Model")
			local offset = aligner.Position - root.CFrame.Position
			local step = math.min(offset.Magnitude, aligner.MaxVelocity * dt)
			if model and step > 1e-4 then
				moveModel(model, root, root.CFrame.Position + offset.Unit * step, Vector3.new(offset.X, 0, offset.Z))
			end
		end
	end

	for humanoid in self._humanoids do
		local model = humanoid.Parent
		local root = model and model:FindFirstChild("HumanoidRootPart")
		if root and root:IsDescendantOf(workspace) then
			-- Roblox's default character Health script regenerates 1 % of max health/s.
			if self._playerHumanoids[humanoid] and humanoid.Health > 0 and humanoid.Health < humanoid.MaxHealth then
				humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + humanoid.MaxHealth * 0.01 * dt)
			end
			if humanoid.Health <= 0 then
				if not self._died[humanoid] then
					self._died[humanoid] = true
					humanoid.Died:Fire()
				end
			elseif not root.Anchored and not driven[root] then
				local position = root.CFrame.Position
				if humanoid.PlatformStand then
					local velocity = root.AssemblyLinearVelocity
					if velocity.Magnitude > 0.01 then
						local nextPosition = position + velocity * dt
						root.AssemblyLinearVelocity = velocity - Vector3.new(0, gravity * dt, 0)
						moveModel(model, root, nextPosition, Vector3.new(velocity.X, 0, velocity.Z))
					end
				else
					local target = self._moveTargets[humanoid]
					local nextPosition = position
					if target then
						local flat = Vector3.new(target.X - position.X, 0, target.Z - position.Z)
						local distance = flat.Magnitude
						if distance > 0.2 then
							local step = flat.Unit * math.min(distance, humanoid.WalkSpeed * dt)
							local candidate = position + step
							local map = self:_mapFor(position)
							local defenses = map and map.Parent:FindFirstChild("Defenses")
							if not self.Geometry:MoveBlocked(map, defenses, position, candidate, root.CollisionGroup, root.Size.X / 2) then
								nextPosition = candidate
							end
						end
					end
					local map = self:_mapFor(nextPosition)
					local groundY = map and self.Geometry:GroundHeight(nextPosition, map)
					if groundY == nil then
						local lobby = workspace:FindFirstChild("Lobby")
						groundY = lobby and self.Geometry:GroundHeight(nextPosition, lobby)
					end
					local standY = if groundY then groundY + humanoid.HipHeight + root.Size.Y / 2 else position.Y - 30 * dt
					local facing = if target then Vector3.new(target.X - position.X, 0, target.Z - position.Z) else nil
					local moved = Vector3.new(nextPosition.X, standY, nextPosition.Z)
					if (moved - position).Magnitude > 1e-3 then
						moveModel(model, root, moved, facing)
					end
				end
			end
		end
	end
end

-- Driving -------------------------------------------------------------------------------------------------

function Engine:Boot()
	local bootstrap = self.ServerRoot:FindFirstChild("Bootstrap")
	local chunk = self:_load(bootstrap)
	self.Scheduler:Spawn(chunk)
	self:Step(FRAME)
end

function Engine:Step(dt)
	self.Frame = (self.Frame or 0) + 1
	local scheduler = self.Scheduler
	scheduler:AdvanceTo(scheduler.Now + dt)
	self.Heartbeat:Fire(dt)
	self:_physics(dt)
end

function Engine:Run(seconds, onFrame)
	local frames = math.max(1, math.floor(seconds / FRAME + 0.5))
	for _ = 1, frames do
		self:Step(FRAME)
		if onFrame and onFrame() then
			return true
		end
	end
	return false
end

-- Runs until predicate() is true or the timeout passes. Returns whether it succeeded.
function Engine:RunUntil(predicate, timeout, onFrame)
	local elapsed = 0
	while elapsed < timeout do
		if predicate() then
			return true
		end
		self:Step(FRAME)
		elapsed += FRAME
		if onFrame then
			onFrame()
		end
	end
	return predicate()
end

function Engine:Shutdown()
	for _, fn in self._bindToClose do
		self.Scheduler:Spawn(fn)
	end
	self:Run(1)
end

return Engine
