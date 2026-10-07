--!strict
--[[
	CleanupService
	Path: ServerScriptService.Server.Services.CleanupService

	Guarantees nothing outlives its match. CleanupMatch tears per-match state down in
	reverse initialisation order (each service's CleanupMatch is isolated with xpcall so
	one failure cannot strand the rest), then destroys the Match (its Janitor owns the
	folder, map, core and state machine).

	A periodic sweep also removes orphans that slipped through a bug: match folders
	whose match no longer exists, and enemy models that are no longer registered.

	Dependencies: Registry: MatchService, EnemyService

	API:
		CleanupService:CleanupMatch(match, serviceNames)
		CleanupService:Sweep() -> number     -- orphans removed (also runs every 30 s)
]]

local Workspace = game:GetService("Workspace")

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)

local SWEEP_INTERVAL = 30

local CleanupService = {}

function CleanupService:Init() end

function CleanupService:Start()
	task.spawn(function()
		while true do
			task.wait(SWEEP_INTERVAL)
			local ok, result = pcall(self.Sweep, self)
			if not ok then
				warn(`[CleanupService] sweep failed: {result}`)
			elseif result > 0 then
				warn(`[CleanupService] removed {result} orphaned objects`)
			end
		end
	end)
end

function CleanupService:CleanupMatch(match: any, serviceNames: { string })
	for index = #serviceNames, 1, -1 do
		local name = serviceNames[index]
		local service = Services[name]
		local ok, err = xpcall(service.CleanupMatch, debug.traceback, service, match)
		if not ok then
			warn(`[CleanupService] {name}:CleanupMatch failed for match {match.Id}: {err}`)
		end
	end
	match:Destroy()
end

function CleanupService:Sweep(): number
	local removed = 0
	local folder = Workspace:FindFirstChild("Matches")
	if folder == nil then
		return 0
	end
	for _, matchFolder in folder:GetChildren() do
		local matchId = matchFolder:GetAttribute("MatchId")
		local match = matchId and Services.MatchService:GetMatch(matchId)
		if match == nil or match.Folder ~= matchFolder then
			matchFolder:Destroy()
			removed += 1
		else
			removed += Services.EnemyService:SweepOrphans(match)
		end
	end
	return removed
end

return CleanupService
