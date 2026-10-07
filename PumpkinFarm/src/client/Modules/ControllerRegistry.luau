--!strict
--[[
	ControllerRegistry
	Path: StarterPlayerScripts.Client.Modules.ControllerRegistry

	Client-side locator filled by ClientBootstrap (mirror of the server Registry).
	Controllers look each other up at call time, never at require time, so the client
	require graph stays acyclic.
]]

local Registry: { [string]: any } = {}

return Registry
