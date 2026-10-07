--!strict
--[[
	DebugConfig
	Path: ServerScriptService.Server.DebugConfig

	Gate for DebugService chat commands. Commands only work when Enabled is true AND
	(the server runs in Studio OR the speaker's UserId is listed). Set Enabled = false
	for production builds to remove the command surface entirely.
]]

return table.freeze({
	Enabled = true,
	AllowInStudio = true,
	AllowedUserIds = {} :: { number },
	Prefix = "/pf",
})
