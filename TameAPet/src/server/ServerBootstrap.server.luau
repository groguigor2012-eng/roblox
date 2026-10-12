-- Server entry point. Order matters:
--   1. remotes exist  2. config is validated  3. world + zones are built
--   4. every service's init() runs (no cross-service calls yet)
--   5. every service's start() runs (binds remotes, connects players, starts loops)
-- Players are not allowed to do anything until DataService has loaded their profile
-- (PlayerStateService.isReady gates every request).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Remotes = require(ServerScriptService.Security.Remotes)
Remotes.ensure()

local ConfigValidator = require(Shared.ConfigValidator)
local problems = ConfigValidator.validate({
	Rarity = require(Config.RarityConfig),
	Pets = require(Config.PetConfig),
	Items = require(Config.ItemConfig),
	Eggs = require(Config.EggConfig),
	Zones = require(Config.ZoneConfig),
	Compasses = require(Config.CompassConfig),
	Shop = require(Config.ShopConfig),
})
for _, problem in problems do
	warn(`[Config] {problem}`)
end

local World = ServerScriptService.World
require(World.MapBuilder).build()
require(World.ZoneRegistry).init()

local ServicesFolder = ServerScriptService.Services
local ORDER = {
	{ "RemoteSecurityService", ServerScriptService.Security.RemoteSecurityService },
	{ "DataService", ServicesFolder.DataService },
	{ "PlayerStateService", ServicesFolder.PlayerStateService },
	{ "NotificationService", ServicesFolder.NotificationService },
	{ "EconomyService", ServicesFolder.EconomyService },
	{ "InventoryService", ServicesFolder.InventoryService },
	{ "PetService", ServicesFolder.PetService },
	{ "MountService", ServicesFolder.MountService },
	{ "TamingService", ServicesFolder.TamingService },
	{ "EggSpawnService", ServicesFolder.EggSpawnService },
	{ "ItemSpawnService", ServicesFolder.ItemSpawnService },
	{ "HatchingService", ServicesFolder.HatchingService },
	{ "EggInteractionService", ServicesFolder.EggInteractionService },
	{ "CompassService", ServicesFolder.CompassService },
}

local services = {}
for _, entry in ORDER do
	services[entry[1]] = require(entry[2])
end

for _, entry in ORDER do
	local ok, err = pcall(services[entry[1]].init, services)
	if not ok then
		error(`[Boot] {entry[1]}.init failed: {err}`)
	end
end
for _, entry in ORDER do
	local ok, err = pcall(services[entry[1]].start)
	if not ok then
		error(`[Boot] {entry[1]}.start failed: {err}`)
	end
end

print(`[Boot] Tame a Pet server ready ({#ORDER} services, {#problems} config warnings)`)
