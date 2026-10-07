--!strict
--[[
	Registry
	Path: ServerScriptService.Server.Registry

	Service locator filled by Bootstrap. Services and runtime classes reach other
	services through this table at call time (never at require time), which keeps the
	require graph acyclic: no service module requires another service module.

	Usage:
		local Services = require(Server.Registry)
		Services.DamageService:DamageEnemy(...)

	Bootstrap assigns every entry before any service's Init runs, so a lookup made
	inside Init/Start/handlers always resolves.
]]

local Registry: { [string]: any } = {}

return Registry
