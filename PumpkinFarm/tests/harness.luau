--[[
	Headless test harness (Lune).

	Maps the Rojo tree onto a fake Instance hierarchy so production modules load
	unmodified: ReplicatedStorage.Shared -> src/shared, ServerScriptService.Server ->
	src/server. `script`, `game`, `require`, `Random`, `task` and the Roblox datatypes
	from @lune/roblox are injected into every module environment.

	Only modules whose logic is pure (or takes injected dependencies) are tested here;
	Roblox engine features (physics, raycasts, pathfinding, players) are exercised by the
	Studio test plan in docs/TESTING.md.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Harness = {}

-- Deterministic Random polyfill (Roblox's Random is not available outside the engine).
local RandomClass = {}
RandomClass.__index = RandomClass
function RandomClass.new(seed: number?)
	local state = math.floor(seed or os.clock() * 1e6) % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	return setmetatable({ _state = state }, RandomClass)
end
function RandomClass:_next(): number
	self._state = (self._state * 48271) % 2147483647
	return self._state
end
function RandomClass:NextNumber(min: number?, max: number?): number
	local unit = (self:_next() - 1) / 2147483646
	if min and max then
		return min + (max - min) * unit
	end
	return unit
end
function RandomClass:NextInteger(min: number, max: number): number
	return min + (self:_next() % (max - min + 1))
end

-- Minimal BindableEvent with a working Event:Wait() for the data-store tests.
local function newBindableEvent()
	local waiters = {}
	local event = {}
	event.Event = {
		Wait = function()
			table.insert(waiters, coroutine.running())
			return coroutine.yield()
		end,
	}
	function event:Fire(...)
		local current = waiters
		waiters = {}
		for _, thread in current do
			task.spawn(thread, ...)
		end
	end
	function event:Destroy() end
	return event
end

local function fakeSignal()
	return { Connect = function() return { Disconnect = function() end } end }
end

local Node = {}
local NODE_METHODS = {}

local function makeNode(name: string, className: string, path: string?, parent: any)
	local node = setmetatable({ _name = name, _class = className, _path = path, _parent = parent, _children = {} }, Node)
	if parent then
		parent._children[name] = node
	end
	return node
end

Node.__index = function(self, key)
	local method = NODE_METHODS[key]
	if method then
		return method
	end
	if key == "Name" then
		return rawget(self, "_name")
	elseif key == "Parent" then
		return rawget(self, "_parent")
	elseif key == "ClassName" then
		return rawget(self, "_class")
	end
	local child = rawget(self, "_children")[key]
	if child == nil then
		error(`{key} is not a valid member of {rawget(self, "_name")}`, 2)
	end
	return child
end

function NODE_METHODS.FindFirstChild(self, name)
	return rawget(self, "_children")[name]
end
function NODE_METHODS.WaitForChild(self, name)
	return rawget(self, "_children")[name]
end
function NODE_METHODS.GetChildren(self)
	local list = {}
	for _, child in rawget(self, "_children") do
		table.insert(list, child)
	end
	return list
end
function NODE_METHODS.FindFirstAncestor(self, name)
	local current = rawget(self, "_parent")
	while current do
		if rawget(current, "_name") == name then
			return current
		end
		current = rawget(current, "_parent")
	end
	return nil
end
function NODE_METHODS.IsA(self, className)
	return rawget(self, "_class") == className
end
function NODE_METHODS.GetAttribute()
	return nil
end
function NODE_METHODS.SetAttribute() end

local function mount(parent, directory: string)
	for _, entry in fs.readDir(directory) do
		local full = directory .. "/" .. entry
		if fs.isDir(full) then
			mount(makeNode(entry, "Folder", nil, parent), full)
		elseif entry:match("%.server%.luau$") then
			makeNode(entry:gsub("%.server%.luau$", ""), "Script", full, parent)
		elseif entry:match("%.client%.luau$") then
			makeNode(entry:gsub("%.client%.luau$", ""), "LocalScript", full, parent)
		elseif entry:match("%.luau$") then
			makeNode(entry:gsub("%.luau$", ""), "ModuleScript", full, parent)
		end
	end
end

local root = makeNode("game", "DataModel", nil, nil)
local replicatedStorage = makeNode("ReplicatedStorage", "ReplicatedStorage", nil, root)
local serverScriptService = makeNode("ServerScriptService", "ServerScriptService", nil, root)
local serverStorage = makeNode("ServerStorage", "ServerStorage", nil, root)
mount(makeNode("Shared", "Folder", nil, replicatedStorage), "src/shared")
mount(makeNode("Server", "Folder", nil, serverScriptService), "src/server")

local clockOffset = 0
local services = {
	ReplicatedStorage = replicatedStorage,
	ServerScriptService = serverScriptService,
	ServerStorage = serverStorage,
	Workspace = {
		GetServerTimeNow = function()
			return os.clock() + clockOffset
		end,
		Gravity = 196.2,
	},
	RunService = {
		IsStudio = function()
			return true
		end,
		Heartbeat = fakeSignal(),
	},
	HttpService = {
		GenerateGUID = function()
			return tostring(math.random(1, 1e9))
		end,
		JSONEncode = function(_, value)
			return serde.encode("json", value)
		end,
		JSONDecode = function(_, value)
			return serde.decode("json", value)
		end,
	},
	Players = { PlayerRemoving = fakeSignal(), PlayerAdded = fakeSignal() },
	DataStoreService = {},
	PhysicsService = {},
	Debris = { AddItem = function() end },
}

-- Permissive stand-in for engine services a module only touches at call time
-- (PathfindingService, TweenService, ...): any member is another callable stub.
local function permissiveStub(name: string): any
	local stub = {}
	return setmetatable(stub, {
		__index = function(_, key)
			return permissiveStub(`{name}.{tostring(key)}`)
		end,
		__call = function()
			return permissiveStub(name .. "()")
		end,
		__tostring = function()
			return `stub<{name}>`
		end,
	})
end

local fakeGame = setmetatable({ PlaceId = 0, JobId = "" }, {
	__index = function(_, key)
		if key == "GetService" then
			return function(_, name)
				local service = services[name]
				if service == nil then
					service = permissiveStub(name)
					services[name] = service
				end
				return service
			end
		end
		return nil
	end,
})

local cache = {}
local fakeInstance = {
	new = function(className: string)
		if className == "BindableEvent" then
			return newBindableEvent()
		end
		return roblox.Instance.new(className)
	end,
}

local function requireNode(node)
	if type(node) ~= "table" or getmetatable(node) ~= Node then
		error("[harness] require expects a module node")
	end
	local path = rawget(node, "_path")
	assert(path, `[harness] {rawget(node, "_name")} is not a module`)
	if cache[path] ~= nil then
		return cache[path]
	end
	local env = {
		script = node,
		game = fakeGame,
		workspace = services.Workspace,
		require = requireNode,
		Random = RandomClass,
		task = task,
		Instance = fakeInstance,
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
		warn = function(...)
			if Harness.ShowWarnings then
				print("[warn]", ...)
			end
		end,
	}
	local source = fs.readFile(path)
	local chunk = luau.load(source, { debugName = path, environment = env })
	local result = chunk()
	cache[path] = result
	return result
end

Harness.Root = root

-- Every ModuleScript node under a root ("Shared" / "Server"), for load smoke tests.
function Harness.AllModules(rootName: string): { any }
	local list = {}
	local function walk(node)
		for _, child in rawget(node, "_children") do
			if rawget(child, "_class") == "ModuleScript" then
				table.insert(list, child)
			end
			walk(child)
		end
	end
	walk(if rootName == "Shared" then replicatedStorage.Shared else serverScriptService.Server)
	return list
end
Harness.Require = requireNode
Harness.Random = RandomClass
Harness.ShowWarnings = false

function Harness.Module(path: string)
	-- "Shared.Config.CropConfig" / "Server.Systems.WaveComposer"
	local parts = string.split(path, ".")
	local node = if parts[1] == "Shared" then replicatedStorage.Shared else serverScriptService.Server
	for index = 2, #parts do
		node = node[parts[index]]
	end
	return requireNode(node)
end

function Harness.Service(name: string): any
	return fakeGame:GetService(name)
end

function Harness.AdvanceClock(seconds: number)
	clockOffset += seconds
end

-- Tiny assertion library -------------------------------------------------------------------

local results = { passed = 0, failed = 0 }
Harness.Results = results

function Harness.test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		results.passed += 1
	else
		results.failed += 1
		print(`FAIL {name}\n    {err}`)
	end
end

function Harness.eq(actual: any, expected: any, message: string?)
	if actual ~= expected then
		error(`{message or "values differ"}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
end

function Harness.ok(condition: any, message: string?)
	if not condition then
		error(message or "assertion failed", 2)
	end
end

function Harness.near(actual: number, expected: number, epsilon: number, message: string?)
	if math.abs(actual - expected) > epsilon then
		error(`{message or "not near"}: expected {expected} +/- {epsilon}, got {actual}`, 2)
	end
end

return Harness
