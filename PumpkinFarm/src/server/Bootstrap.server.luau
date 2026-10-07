--!strict
--[[
	Bootstrap
	Path: ServerScriptService.Server.Bootstrap (Script)

	The only server Script. Requires every service, registers it in the Registry, then
	runs Init on all of them (wiring only, no cross-service calls) and Start on all of
	them (connect events, start loops) in the fixed order below. Failures are isolated
	and reported per service.

	Order rationale:
	  * RemoteService first: it creates ReplicatedStorage.Remotes that clients wait on
	  * DataService early: profiles must load before anything reads them
	  * LobbyService builds the lobby in Init, so it exists before PlayerService:Start
	    begins spawning players
	  * PlayerService starts last among gameplay services: when it fires, everything a
	    joining player touches is ready
]]

local Server = script.Parent
local Registry = require(Server.Registry)
local CollisionGroups = require(Server.Systems.CollisionGroups)
local MapBuilder = require(Server.Systems.MapBuilder)

local SERVICE_ORDER = {
	"RemoteService",
	"DataService",
	"CandyService",
	"MatchCoinService",
	"CurrencyService",
	"DifficultyService",
	"StatusEffectService",
	"StunService",
	"EffectService",
	"DamageService",
	"RewardService",
	"UpgradeService",
	"ClassService",
	"WeaponService",
	"SeedService",
	"CropService",
	"SeedShopService",
	"HarvestChestService",
	"BarricadeService",
	"SentryService",
	"DefenseService",
	"EnemyService",
	"WaveService",
	"EscapeService",
	"CleanupService",
	"MatchService",
	"LobbyService",
	"PlayerService",
	"DebugService",
}

CollisionGroups.Setup()
MapBuilder.ConfigureLighting()

for _, name in SERVICE_ORDER do
	local moduleScript = Server.Services:FindFirstChild(name)
	assert(moduleScript and moduleScript:IsA("ModuleScript"), `[Bootstrap] missing service module {name}`)
	Registry[name] = (require :: any)(moduleScript)
end

local function runPhase(phase: string)
	for _, name in SERVICE_ORDER do
		local service = Registry[name]
		local method = service[phase]
		if method then
			local ok, err = xpcall(method, debug.traceback, service)
			if not ok then
				warn(`[Bootstrap] {name}:{phase} failed: {err}`)
			end
		end
	end
end

runPhase("Init")
runPhase("Start")
Registry.RemoteService:VerifyHandlers()

print(`[Bootstrap] Protect the Pumpkin Farm server ready ({#SERVICE_ORDER} services)`)
