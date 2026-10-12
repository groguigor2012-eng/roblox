-- The taming transaction. The client sends only a pet id; the required item comes from
-- PetConfig, ownership/status/quantity are checked on the server, and the item is consumed
-- and the status flipped in one atomic step (Data/Transactions.tamePet). The player's
-- transaction lock (RemoteSecurityService) stops two concurrent requests from racing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PetConfig = require(ReplicatedStorage.Config.PetConfig)
local ItemConfig = require(ReplicatedStorage.Config.ItemConfig)
local RemoteNames = require(ReplicatedStorage.Shared.RemoteNames)
local Transactions = require(ServerScriptService.Data.Transactions)
local Validate = require(ServerScriptService.Security.Validate)

local Codes = RemoteNames.Codes

local TamingService = {}
TamingService.Name = "TamingService"

local Services

local function tame(player: Player, petId: string)
	local Security = Services.RemoteSecurityService
	local data = Services.DataService.getData(player)
	if not data then
		return Security.fail(Codes.NotReady, "Your data is still loading.")
	end

	local ok, code, details = Transactions.tamePet(data, Services.DataService.context(), petId)
	if not ok then
		if code == Codes.NotOwned then
			-- Either a stale UI or an attempt to tame someone else's pet.
			Security.report(player, "TamePet", `pet {petId} is not owned by this player`)
			return Security.fail(code, "That pet isn't yours.")
		elseif code == Codes.AlreadyTamed then
			return Security.fail(code, "That pet is already tamed.")
		elseif code == Codes.MissingItem then
			local item = details and ItemConfig.Items[details.itemId]
			local name = if item then item.displayName else "the required item"
			return Security.fail(code, `You need a {name} to tame this pet.`)
		end
		warn(`[Taming] {player.Name} could not tame {petId}: {code}`)
		return Security.fail(code, "This pet can't be tamed right now.")
	end

	Services.DataService.markDirty(player)
	local species = PetConfig.Species[details.species]
	local name = if species then species.displayName else details.species
	Services.NotificationService.notify(player, "success", `You tamed your {name}! Equip it to ride.`, species and species.rarity)
	return Security.ok({ petId = petId, species = details.species })
end

function TamingService.init(services)
	Services = services
end

function TamingService.start()
	Services.RemoteSecurityService.bindFunction("TamePet", { action = "TamePet", args = { Validate.id(64) } }, tame)
end

return TamingService
