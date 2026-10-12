-- Headless test runner (Lune: https://lune-org.github.io). Run from the TameAPet folder:
--   lune run tests/run.luau
-- Loads the game's pure modules (gameplay rules, data transactions, physics model, security
-- helpers) outside Roblox with a tiny `script`/`require` shim that mirrors the Rojo layout.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local Random = require("./random")

-- Virtual DataModel path -> source directory (mirrors default.project.json).
local MOUNTS = {
	["ReplicatedStorage/Shared"] = "src/shared",
	["ReplicatedStorage/Config"] = "src/config",
	["ServerScriptService/Data"] = "src/server/Data",
	["ServerScriptService/Services"] = "src/server/Services",
	["ServerScriptService/Security"] = "src/server/Security",
	["ServerScriptService/World"] = "src/server/World",
}

local globals = {
	Vector3 = roblox.Vector3,
	Vector2 = roblox.Vector2,
	CFrame = roblox.CFrame,
	Color3 = roblox.Color3,
	UDim = roblox.UDim,
	UDim2 = roblox.UDim2,
	Enum = roblox.Enum,
	Random = Random,
}

local loaded: { [string]: any } = {}
local nodeMeta = {}

local function node(virtualPath: string)
	return setmetatable({ __path = virtualPath }, nodeMeta)
end

nodeMeta.__index = function(self, key)
	local path = rawget(self, "__path")
	if key == "Parent" then
		return node((path:match("^(.*)/[^/]+$")) or "")
	end
	return node(if path == "" then key else path .. "/" .. key)
end

local function resolve(virtualPath: string): string?
	for mount, dir in MOUNTS do
		if virtualPath:sub(1, #mount + 1) == mount .. "/" then
			return dir .. "/" .. virtualPath:sub(#mount + 2) .. ".luau"
		end
	end
	return nil
end

local requireNode
local function load(virtualPath: string)
	if loaded[virtualPath] ~= nil then
		return loaded[virtualPath]
	end
	local file = resolve(virtualPath)
	assert(file and fs.isFile(file), `cannot resolve module {virtualPath}`)
	-- Lune copies environment fields (metatables are not consulted), so build it flat.
	local env = table.clone(globals)
	env.script = node(virtualPath)
	env.require = requireNode
	local chunk = luau.load(fs.readFile(file), { debugName = file, environment = env })
	local result = chunk()
	loaded[virtualPath] = result
	return result
end

requireNode = function(target)
	if type(target) == "table" and rawget(target, "__path") then
		return load(rawget(target, "__path"))
	end
	error("tests can only require game modules")
end

-- Tiny test harness ---------------------------------------------------------------------------

local passed, failed = 0, 0
local currentSuite = ""

local T = {}
function T.describe(name: string, fn: () -> ())
	currentSuite = name
	fn()
end
function T.it(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		print(`FAIL  {currentSuite} > {name}\n      {err}`)
	end
end
function T.expect(value: any)
	return {
		toBe = function(expected)
			if value ~= expected then
				error(`expected {tostring(expected)}, got {tostring(value)}`, 2)
			end
		end,
		toBeNear = function(expected, tolerance)
			if math.abs(value - expected) > tolerance then
				error(`expected ~{expected} (±{tolerance}), got {value}`, 2)
			end
		end,
		toBeTruthy = function()
			if not value then
				error(`expected truthy, got {tostring(value)}`, 2)
			end
		end,
		toBeFalsy = function()
			if value then
				error(`expected falsy, got {tostring(value)}`, 2)
			end
		end,
		atMost = function(limit)
			if value > limit then
				error(`expected <= {limit}, got {value}`, 2)
			end
		end,
	}
end
T.load = function(path: string)
	return load(path)
end

for _, file in fs.readDir("tests/specs") do
	if file:match("%.luau$") then
		local chunk = luau.load(fs.readFile("tests/specs/" .. file), {
			debugName = file,
			environment = (function()
				local env = table.clone(globals)
				env.T = T
				return env
			end)(),
		})
		chunk()
	end
end

print(`\n{passed} passed, {failed} failed`)
process.exit(if failed == 0 then 0 else 1)
