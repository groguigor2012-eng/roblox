--!nocheck
-- Static integration checks over the framework sources:
--   1. every config reference in code (XConfig.A.B, or alias.B where
--      `local alias = XConfig.A`) names a key that exists
--   2. every config leaf is used somewhere outside the config files
--   3. every remote in GameConfig.Remotes is declared in Types.Remotes and is
--      used in the documented direction on both sides (FireServer +
--      OnServerEvent, or FireClient + OnClientEvent)

local process = require("@lune/process")
local H = require("./harness")

local CONFIGS = {
	GameConfig = H.load("shared/Config/GameConfig"),
	MovementConfig = H.load("shared/Config/MovementConfig"),
	CollectibleConfig = H.load("shared/Config/CollectibleConfig"),
	HealthUIConfig = H.load("shared/Config/HealthUIConfig"),
	DataConfig = H.load("shared/Config/DataConfig"),
	AnimationConfig = H.load("shared/Config/AnimationConfig"),
	CombatConfig = H.load("shared/Config/CombatConfig"),
}

-- Tables indexed by runtime keys (iterated or looked up by a variable): treat as leaves.
local MAP_TABLES = {
	["GameConfig.Remotes"] = true,
	["GameConfig.Progression.TrustedRewardSources"] = true,
	["CollectibleConfig.DefaultRewards"] = true,
	["CollectibleConfig.Visual.Colors"] = true,
	["CollectibleConfig.Visual.DisplayNames"] = true,
	["CombatConfig.Attack.BlockedStates"] = true,
	-- Passed whole to a consumer; its fields are checked below.
	["CombatConfig.Attack.Fallback"] = true,
	["AnimationConfig.Attack"] = true,
	["AnimationConfig.DoubleJumpSpin"] = true,
	["AnimationConfig.DashRoll"] = true,
}

local sources = H.sources()
local codeFiles = {}
for path, source in sources do
	if not string.find(path, "/Config/", 1, true) then
		codeFiles[path] = source
	end
end

local function isArray(value)
	return type(value) == "table" and #value > 0
end

local function lookup(root, segments)
	local node = root
	for _, segment in segments do
		if type(node) ~= "table" or node[segment] == nil then
			return false
		end
		node = node[segment]
	end
	return true
end

local function escape(text)
	return (string.gsub(text, "%p", "%%%0"))
end

------------------------------------------------------------------------------
H.suite("Config references resolve")

H.test("every XConfig.path and alias.path in code exists", function()
	local missing = {}
	for path, source in codeFiles do
		local aliases = {}
		for alias, configName, rest in string.gmatch(source, "local%s+([%w_]+)%s*=%s*(%u%w*Config)%.([%w_%.]+)") do
			if CONFIGS[configName] then
				aliases[alias] = { configName, rest }
			end
		end
		for configName, rest in string.gmatch(source, "(%u%w*Config)%.([%w_%.]+)") do
			local config = CONFIGS[configName]
			if config then
				local segments = string.split(rest, ".")
				-- Drop trailing method/property access on a value (e.g. ".Value" on an EnumItem).
				if not lookup(config, segments) and not lookup(config, { table.unpack(segments, 1, #segments - 1) }) then
					table.insert(missing, `{path}: {configName}.{rest}`)
				end
			end
		end
		for alias, target in aliases do
			for position, rest in string.gmatch(source, "()%f[%w_]" .. escape(alias) .. "%.([%w_]+)") do
				-- Skip "Other.Alias.Key": that is a member of something else, not the alias.
				if position > 1 and string.sub(source, position - 1, position - 1) == "." then
					continue
				end
				local segments = string.split(target[2], ".")
				table.insert(segments, rest)
				if not lookup(CONFIGS[target[1]], segments) then
					table.insert(missing, `{path}: {alias}.{rest} (= {target[1]}.{target[2]}.{rest})`)
				end
			end
		end
	end
	if #missing > 0 then
		error("unknown config keys:\n    " .. table.concat(missing, "\n    "))
	end
end)

------------------------------------------------------------------------------
H.suite("Config keys are used")

H.test("every config leaf is referenced outside the config files", function()
	local unused = {}
	local function visit(path, segments, value)
		local isRecord = type(value) == "table" and not isArray(value) and not MAP_TABLES[path]
		if isRecord then
			for key, child in value do
				local childSegments = table.clone(segments)
				table.insert(childSegments, key)
				visit(`{path}.{key}`, childSegments, child)
			end
			return
		end
		local key = segments[#segments]
		local parent = segments[#segments - 1]
		local keyPattern = "[%.:]" .. escape(key) .. "%f[^%w_]"
		local used = false
		for _, source in codeFiles do
			if string.find(source, keyPattern) and string.find(source, "%f[%w_]" .. escape(parent) .. "%f[^%w_]") then
				used = true
				break
			end
		end
		if not used then
			table.insert(unused, path)
		end
	end
	for name, config in CONFIGS do
		visit(name, { name }, config)
	end
	table.sort(unused)
	if #unused > 0 then
		error("unused config keys:\n    " .. table.concat(unused, "\n    "))
	end
end)

H.test("records passed whole are fully consumed by their reader", function()
	local readers = {
		{ CONFIGS.CombatConfig.Attack.Fallback, "platformer/src/shared/Math/AttackMath.luau", "pose" },
		{ CONFIGS.AnimationConfig.Attack, "platformer/src/client/Utilities/CharacterAnimations.luau", "entry" },
	}
	for _, reader in readers do
		local source = sources[reader[2]]
		for key in reader[1] do
			H.truthy(string.find(source, reader[3] .. "." .. key, 1, true), `{reader[2]} reads {reader[3]}.{key}`)
		end
	end
end)

------------------------------------------------------------------------------
H.suite("Remote contract")

local gameConfigSource = sources["platformer/src/shared/Config/GameConfig.luau"]
local typesSource = sources["platformer/src/shared/Types.luau"]
local directions = {}
for name, from, to in string.gmatch(gameConfigSource, "%-%-%s+(%w+)%s+(%w+)%s*%->%s*(%w+)") do
	directions[name] = `{from}->{to}`
end

local function filesUnder(prefix)
	local list = {}
	for path, source in codeFiles do
		if string.sub(path, 1, #prefix) == prefix then
			table.insert(list, source)
		end
	end
	return table.concat(list, "\n")
end
local serverCode = filesUnder("platformer/src/server/")
local clientCode = filesUnder("platformer/src/client/")

for name, className in CONFIGS.GameConfig.Remotes do
	H.test(`{name} ({className}) is declared, documented and wired both ways`, function()
		H.truthy(string.find(typesSource, "%s" .. name .. ":%s*" .. className), "declared in Types.Remotes")
		local direction = directions[name]
		H.truthy(direction, "direction documented in GameConfig")
		if direction == "client->server" then
			H.truthy(string.find(clientCode, name .. ":FireServer", 1, true), "client fires it")
			H.truthy(string.find(serverCode, name .. ".OnServerEvent", 1, true), "server handles it")
		else
			H.truthy(string.find(serverCode, name .. ":FireClient", 1, true), "server fires it")
			H.truthy(string.find(clientCode, name .. ".OnClientEvent", 1, true), "client handles it")
		end
	end)
end

H.test("Types.Remotes has no remotes missing from GameConfig", function()
	local block = string.match(typesSource, "export type Remotes = (%b{})")
	for name in string.gmatch(block, "(%w+):%s*RemoteEvent") do
		H.truthy(CONFIGS.GameConfig.Remotes[name], `{name} in GameConfig.Remotes`)
	end
end)

process.exit(if H.summary() == 0 then 0 else 1)
