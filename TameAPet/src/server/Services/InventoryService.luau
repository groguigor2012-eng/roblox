-- Server-side inventory operations (pets, items, compasses). Wraps Data/Transactions with
-- syncing and handles the EquipCompass request.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CompassConfig = require(ReplicatedStorage.Config.CompassConfig)
local RemoteNames = require(ReplicatedStorage.Shared.RemoteNames)
local Transactions = require(ServerScriptService.Data.Transactions)
local Validate = require(ServerScriptService.Security.Validate)

local Codes = RemoteNames.Codes

local InventoryService = {}
InventoryService.Name = "InventoryService"

local Services

function InventoryService.hasPetSpace(player: Player): boolean
	local data = Services.DataService.getData(player)
	return data ~= nil and Transactions.hasPetSpace(data, Services.DataService.context())
end

function InventoryService.canAddItem(player: Player, itemId: string): boolean
	local data = Services.DataService.getData(player)
	return data ~= nil and Transactions.canAddItem(data, Services.DataService.context(), itemId)
end

-- Returns the new pet record, or nil + code.
function InventoryService.addPet(player: Player, speciesId: string, eggTier: string)
	local data = Services.DataService.getData(player)
	if not data then
		return nil, Codes.NotReady
	end
	local pet, code = Transactions.addPet(data, Services.DataService.context(), speciesId, eggTier)
	if pet then
		Services.DataService.markDirty(player)
	end
	return pet, code
end

function InventoryService.addItem(player: Player, itemId: string, quantity: number): (number, string)
	local data = Services.DataService.getData(player)
	if not data then
		return 0, Codes.NotReady
	end
	local added, code = Transactions.addItem(data, Services.DataService.context(), itemId, quantity)
	if added > 0 then
		Services.DataService.markDirty(player)
	end
	return added, code
end

function InventoryService.getPet(player: Player, petId: string)
	local data = Services.DataService.getData(player)
	return if data then data.pets[petId] else nil
end

function InventoryService.getEquippedCompass(player: Player)
	local data = Services.DataService.getData(player)
	if not data or data.equippedCompass == "" then
		return nil, nil
	end
	return data.equippedCompass, CompassConfig.Compasses[data.equippedCompass]
end

local function equipCompass(player: Player, compassId: string)
	local Security = Services.RemoteSecurityService
	local data = Services.DataService.getData(player)
	if not data then
		return Security.fail(Codes.NotReady)
	end
	local ok, code = Transactions.equipCompass(data, Services.DataService.context(), compassId)
	if not ok then
		if code == Codes.NotOwned then
			return Security.fail(code, "You don't own that compass yet. Buy it in the shop.")
		end
		return Security.fail(code, "You can't equip that.")
	end
	Services.DataService.markDirty(player)
	Services.CompassService.refresh(player)
	return Security.ok()
end

function InventoryService.init(services)
	Services = services
end

function InventoryService.start()
	Services.RemoteSecurityService.bindFunction(
		"EquipCompass",
		{ action = "EquipCompass", args = { Validate.optionalId(48) } },
		equipCompass
	)
end

return InventoryService
