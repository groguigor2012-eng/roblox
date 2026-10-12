-- Handles a player triggering an egg's ProximityPrompt. The egg id comes from the server-side
-- prompt binding, never from the client. Checks, in order:
--   profile loaded + rate limit, egg still active, distance, zone eligibility, pet space,
-- then atomically claims the egg (only one player can win) and hands it to HatchingService.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Config.GameConfig)
local ZoneConfig = require(ReplicatedStorage.Config.ZoneConfig)
local ZoneRegistry = require(ServerScriptService.World.ZoneRegistry)

local EggInteractionService = {}
EggInteractionService.Name = "EggInteractionService"

local Services

local function onTriggered(player: Player, eggId: string)
	local Security = Services.RemoteSecurityService
	local Notify = Services.NotificationService

	local allowed, message = Security.checkInteraction(player, "EggClaim")
	if not allowed then
		if message then
			Notify.notify(player, "error", message)
		end
		return
	end

	local egg = Services.EggSpawnService.getActive(eggId)
	if not egg then
		Notify.notify(player, "error", "That egg is gone.")
		return
	end

	local distance = Security.distanceTo(player, egg.position)
	local maxDistance = GameConfig.Interaction.EggPromptDistance + GameConfig.Interaction.DistanceTolerance
	if not distance or distance > maxDistance then
		Security.report(player, "EggClaim", `too far from egg ({distance and math.floor(distance) or "no character"} studs)`)
		return
	end

	local data = Services.DataService.getData(player)
	if not data then
		return
	end
	if not ZoneRegistry.isUnlocked(data, egg.zoneId) then
		local zone = ZoneConfig.get(egg.zoneId)
		Notify.notify(player, "error", `Buy the {zone and zone.displayName or egg.zoneId} pass in the shop to hatch eggs here.`)
		return
	end
	if not Services.InventoryService.hasPetSpace(player) then
		Notify.notify(player, "error", `Your pet inventory is full ({GameConfig.MaxPets}).`)
		return
	end

	-- Atomic claim. Any other request for this egg, now or later, fails here.
	local claimed = Services.EggSpawnService.claim(eggId, player)
	if not claimed then
		Notify.notify(player, "error", "Someone else got to that egg first!")
		return
	end

	local ok, err = pcall(Services.HatchingService.hatch, player, claimed)
	if ok and err == true then
		Services.EggSpawnService.remove(eggId, "Claimed")
	else
		-- Nothing was granted: put the egg back so it isn't lost.
		if not ok then
			warn(`[Eggs] Hatch failed for {player.Name}: {err}`)
		end
		Services.EggSpawnService.release(eggId)
		Notify.notify(player, "error", "The egg wouldn't hatch. Try again.")
	end
end

function EggInteractionService.init(services)
	Services = services
end

function EggInteractionService.start()
	Services.EggSpawnService.PromptTriggered:Connect(onTriggered)
end

return EggInteractionService
