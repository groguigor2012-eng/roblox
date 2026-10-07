--!strict
--[[
	ClientBootstrap
	Path: StarterPlayerScripts.Client.ClientBootstrap (LocalScript)

	The only client script. Waits for the game to load, starts ClientState, then
	registers every controller and runs Init (build UI, no cross-controller calls) and
	Start (connect events) in a fixed order. A failing controller is reported and the
	rest keep working.
]]

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Client = script.Parent
local Controllers = require(Client.Modules.ControllerRegistry)
local ClientState = require(Client.Modules.ClientState)

local CONTROLLER_ORDER = {
	"NotificationController",
	"AudioController",
	"EffectsController",
	"HUDController",
	"WaveUIController",
	"LobbyController",
	"ClassController",
	"SeedShopController",
	"CropController",
	"HarvestChestController",
	"DefenseShopController",
	"EscapeController",
	"WeaponController",
	"BossBarController",
}

for _, name in CONTROLLER_ORDER do
	local moduleScript = Client.Controllers:WaitForChild(name, 10)
	assert(moduleScript and moduleScript:IsA("ModuleScript"), `[ClientBootstrap] missing controller {name}`)
	Controllers[name] = (require :: any)(moduleScript)
end

local function runPhase(phase: string)
	for _, name in CONTROLLER_ORDER do
		local controller = Controllers[name]
		local method = controller[phase]
		if method then
			local ok, err = xpcall(method, debug.traceback, controller)
			if not ok then
				warn(`[ClientBootstrap] {name}:{phase} failed: {err}`)
			end
		end
	end
end

runPhase("Init")
ClientState.Start()
runPhase("Start")
