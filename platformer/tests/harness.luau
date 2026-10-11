--!nocheck
-- Headless test harness for Lune (https://lune-org.github.io).
--
-- Loads the framework's pure modules outside Roblox by mapping the Rojo
-- layout onto the file system: `script`, `script.Parent.X`,
-- `game:GetService("ReplicatedStorage").Shared.X` and `:WaitForChild("X")`
-- all resolve to files under platformer/src, and `require` runs them with
-- Lune's Roblox datatypes (Vector3, Enum, ...) as globals.
--
-- Only modules that do not touch live services at load time can be loaded
-- this way (configs, math, schema, session lock, retry, profile store,
-- rate limiter, cleanup, logger). Services and controllers are verified by
-- luau-lsp type checking and in Studio.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local Harness = {}

local SRC = "platformer/src"

local NodeMeta = {}
local cache: { [string]: any } = {}

-- File-system calls yield in Lune and cannot run inside metamethods, so the
-- whole source tree is indexed (and read) once, up front.
local directories: { [string]: boolean } = {}
local sources: { [string]: string } = {}

local function indexTree(path: string)
	directories[path] = true
	for _, entry in fs.readDir(path) do
		local child = path .. "/" .. entry
		if fs.isDir(child) then
			indexTree(child)
		elseif string.sub(entry, -5) == ".luau" then
			sources[child] = fs.readFile(child)
		end
	end
end
indexTree(SRC)

local function makeNode(path: string, name: string, parent: any): any
	return setmetatable({ __path = path, __name = name, __parent = parent }, NodeMeta)
end

local function findChild(node: any, name: string): any
	local base = rawget(node, "__path") .. "/" .. name
	if directories[base] then
		return makeNode(base, name, node)
	end
	for _, extension in { ".luau", ".server.luau", ".client.luau" } do
		if sources[base .. extension] then
			return makeNode(base .. extension, name, node)
		end
	end
	return nil
end

NodeMeta.__index = function(node, key)
	if key == "Parent" then
		return rawget(node, "__parent")
	elseif key == "Name" then
		return rawget(node, "__name")
	elseif key == "WaitForChild" or key == "FindFirstChild" then
		return function(self, name)
			return findChild(self, name)
		end
	end
	local child = findChild(node, key)
	if child == nil then
		error(`{rawget(node, "__path")} has no child "{key}"`, 2)
	end
	return child
end

local services = {
	ReplicatedStorage = { Shared = makeNode(SRC .. "/shared", "Shared", nil) },
	ServerScriptService = { Server = makeNode(SRC .. "/server", "Server", nil) },
}

local fakeGame = {
	GetService = function(_, name: string)
		local service = services[name]
		if not service then
			error(`service {name} is not available in headless tests`, 2)
		end
		return service
	end,
}

local warnings: { string } = {}

local requireNode

local function environment(scriptNode: any): { [string]: any }
	return {
		script = scriptNode,
		require = requireNode,
		game = fakeGame,
		task = task,
		warn = function(...)
			local parts = {}
			for index = 1, select("#", ...) do
				table.insert(parts, tostring((select(index, ...))))
			end
			table.insert(warnings, table.concat(parts, " "))
		end,
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
	}
end

requireNode = function(node: any): any
	local path = rawget(node, "__path")
	if cache[path] ~= nil then
		return cache[path]
	end
	local source = sources[path]
	assert(source, `require target is not a module: {path}`)
	local chunk = luau.load(source, {
		debugName = path,
		environment = environment(node),
	})
	local result = chunk()
	cache[path] = result
	return result
end

-- Harness.load("shared/Math/MovementMath") or ("server/Utilities/ProfileStore")
function Harness.load(relativePath: string): any
	local parts = string.split(relativePath, "/")
	local node = makeNode(SRC .. "/" .. parts[1], parts[1], nil)
	for index = 2, #parts do
		node = findChild(node, parts[index]) or error(`no module {relativePath}`)
	end
	return requireNode(node)
end

-- All framework sources, keyed by path (for static checks).
function Harness.sources(): { [string]: string }
	return sources
end

function Harness.takeWarnings(): { string }
	local taken = warnings
	warnings = {}
	return taken
end

------------------------------------------------------------------------------
-- Minimal test runner
------------------------------------------------------------------------------

local results = { passed = 0, failed = 0, failures = {} :: { string } }
local currentSuite = ""

function Harness.suite(name: string)
	currentSuite = name
	print(`\n{name}`)
end

function Harness.test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		results.passed += 1
		print(`  ok   {name}`)
	else
		results.failed += 1
		table.insert(results.failures, `{currentSuite} > {name}: {err}`)
		print(`  FAIL {name}\n       {err}`)
	end
end

function Harness.eq(actual: any, expected: any, label: string?)
	if actual ~= expected then
		error(`{label or "value"}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
end

function Harness.near(actual: number, expected: number, tolerance: number, label: string?)
	if math.abs(actual - expected) > tolerance then
		error(`{label or "value"}: expected {expected} ± {tolerance}, got {actual}`, 2)
	end
end

function Harness.truthy(value: any, label: string?)
	if not value then
		error(`{label or "condition"} was {tostring(value)}`, 2)
	end
end

function Harness.summary(): number
	print(`\n{results.passed} passed, {results.failed} failed`)
	for _, failure in results.failures do
		print(`  - {failure}`)
	end
	return results.failed
end

return Harness
