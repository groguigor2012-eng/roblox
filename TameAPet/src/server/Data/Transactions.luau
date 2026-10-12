--!strict
-- Every change to a profile goes through these functions. They are pure (no yields, no
-- Roblox APIs) so each one runs to completion atomically on the server's single Lua thread
-- and can be unit-tested. Each validates EVERYTHING before mutating anything, so a failed
-- transaction leaves the profile untouched.
--
-- Services own security (rate limits, ownership of the calling player, distance checks)
-- and side effects (syncing, notifications); this module owns the rules of the data.

local ProfileSchema = require(script.Parent.ProfileSchema)

type ProfileData = ProfileSchema.ProfileData
type PetRecord = ProfileSchema.PetRecord

export type Context = {
	Pets: { [string]: any }, -- PetConfig.Species
	Items: { [string]: any }, -- ItemConfig.Items
	Compasses: { [string]: any }, -- CompassConfig.Compasses
	Products: { any }, -- ShopConfig.Products
	Zones: { any }, -- ZoneConfig.Zones
	maxPets: number,
	maxItemStack: number,
	maxCurrency: number,
	speedUpgradePrice: (product: any, level: number) -> number?,
	now: () -> number,
	newId: () -> string,
}

local Transactions = {}

-- Currency ---------------------------------------------------------------------------------

local function isWholePositive(amount: any): boolean
	return type(amount) == "number" and amount == amount and amount > 0 and amount < math.huge and amount % 1 == 0
end

function Transactions.addCurrency(data: ProfileData, ctx: Context, amount: number): number
	if not isWholePositive(amount) then
		return 0
	end
	local before = data.currency
	data.currency = math.min(before + amount, ctx.maxCurrency)
	local added = data.currency - before
	data.stats.coinsEarned += added
	return added
end

function Transactions.spend(data: ProfileData, amount: number): boolean
	if not isWholePositive(amount) or data.currency < amount then
		return false
	end
	data.currency -= amount
	return true
end

-- Pets -------------------------------------------------------------------------------------

function Transactions.countPets(data: ProfileData): number
	local count = 0
	for _ in data.pets do
		count += 1
	end
	return count
end

function Transactions.hasPetSpace(data: ProfileData, ctx: Context): boolean
	return Transactions.countPets(data) < ctx.maxPets
end

function Transactions.addPet(data: ProfileData, ctx: Context, speciesId: string, eggTier: string): (PetRecord?, string)
	local species = ctx.Pets[speciesId]
	if not species then
		return nil, "ConfigError"
	end
	if not Transactions.hasPetSpace(data, ctx) then
		return nil, "InventoryFull"
	end
	local id = ctx.newId()
	if data.pets[id] ~= nil then
		return nil, "ServerError" -- id collision; never overwrite an existing pet
	end
	local pet: PetRecord = {
		id = id,
		species = speciesId,
		rarity = species.rarity,
		eggTier = eggTier,
		status = "Untamed",
		acquiredAt = ctx.now(),
		tamedAt = 0,
	}
	data.pets[id] = pet
	data.stats.eggsHatched += 1
	return pet, "Ok"
end

-- Items ------------------------------------------------------------------------------------

function Transactions.itemCount(data: ProfileData, itemId: string): number
	return data.items[itemId] or 0
end

function Transactions.canAddItem(data: ProfileData, ctx: Context, itemId: string): boolean
	return ctx.Items[itemId] ~= nil and Transactions.itemCount(data, itemId) < ctx.maxItemStack
end

function Transactions.addItem(data: ProfileData, ctx: Context, itemId: string, quantity: number): (number, string)
	if not ctx.Items[itemId] then
		return 0, "ConfigError"
	end
	if not isWholePositive(quantity) then
		return 0, "BadRequest"
	end
	local current = Transactions.itemCount(data, itemId)
	local room = ctx.maxItemStack - current
	if room <= 0 then
		return 0, "InventoryFull"
	end
	local added = math.min(room, quantity)
	data.items[itemId] = current + added
	data.stats.itemsCollected += added
	return added, "Ok"
end

function Transactions.consumeItem(data: ProfileData, itemId: string, quantity: number): boolean
	if not isWholePositive(quantity) then
		return false
	end
	local current = Transactions.itemCount(data, itemId)
	if current < quantity then
		return false
	end
	local remaining = current - quantity
	data.items[itemId] = (if remaining > 0 then remaining else nil) :: any
	return true
end

-- Taming -----------------------------------------------------------------------------------

-- The required item always comes from trusted config, never from the request.
function Transactions.tamePet(data: ProfileData, ctx: Context, petId: string): (boolean, string, { [string]: any }?)
	local pet = data.pets[petId]
	if not pet then
		return false, "NotOwned", nil
	end
	if pet.status ~= "Untamed" then
		return false, "AlreadyTamed", nil
	end
	local species = ctx.Pets[pet.species]
	if not species then
		return false, "ConfigError", nil
	end
	local itemId = species.requiredItem
	if not ctx.Items[itemId] then
		return false, "ConfigError", nil
	end
	if Transactions.itemCount(data, itemId) < 1 then
		return false, "MissingItem", { itemId = itemId }
	end

	-- Commit: consume exactly one item, then flip the status. Roll back if anything fails.
	local itemsBefore = data.items[itemId]
	if not Transactions.consumeItem(data, itemId, 1) then
		return false, "MissingItem", { itemId = itemId }
	end
	local ok = pcall(function()
		pet.status = "Tamed"
		pet.tamedAt = ctx.now()
		data.stats.petsTamed += 1
	end)
	if not ok then
		data.items[itemId] = itemsBefore :: any
		pet.status = "Untamed"
		pet.tamedAt = 0
		return false, "ServerError", nil
	end
	return true, "Ok", { itemId = itemId, species = pet.species }
end

-- Equipment --------------------------------------------------------------------------------

-- petId = "" unequips.
function Transactions.equipPet(data: ProfileData, ctx: Context, petId: string): (boolean, string)
	if petId == "" then
		data.equippedPetId = ""
		return true, "Ok"
	end
	local pet = data.pets[petId]
	if not pet then
		return false, "NotOwned"
	end
	if pet.status ~= "Tamed" then
		return false, "NotTamed"
	end
	if not ctx.Pets[pet.species] then
		return false, "ConfigError"
	end
	data.equippedPetId = petId
	return true, "Ok"
end

-- compassId = "" unequips.
function Transactions.equipCompass(data: ProfileData, ctx: Context, compassId: string): (boolean, string)
	if compassId == "" then
		data.equippedCompass = ""
		return true, "Ok"
	end
	if not ctx.Compasses[compassId] then
		return false, "NotFound"
	end
	if not data.compasses[compassId] then
		return false, "NotOwned"
	end
	data.equippedCompass = compassId
	return true, "Ok"
end

-- Shop -------------------------------------------------------------------------------------

local function findProduct(ctx: Context, productId: string): any?
	for _, product in ctx.Products do
		if product.id == productId then
			return product
		end
	end
	return nil
end

-- Returns the server-side price of a product for this profile, or nil + reason when it
-- cannot be bought right now.
function Transactions.quote(data: ProfileData, ctx: Context, productId: string): (number?, string)
	local product = findProduct(ctx, productId)
	if not product then
		return nil, "NotFound"
	end
	if product.kind == "Compass" then
		if not ctx.Compasses[product.compassId] then
			return nil, "ConfigError"
		end
		if data.compasses[product.compassId] then
			return nil, "AlreadyOwned"
		end
		return product.price, "Ok"
	elseif product.kind == "ZoneUnlock" then
		if data.unlockedZones[product.zoneId] then
			return nil, "AlreadyOwned"
		end
		if product.requires and not data.unlockedZones[product.requires] then
			return nil, "Locked"
		end
		return product.price, "Ok"
	elseif product.kind == "SpeedUpgrade" then
		local price = ctx.speedUpgradePrice(product, data.speedUpgradeLevel)
		if not price then
			return nil, "Maxed"
		end
		return price, "Ok"
	end
	return nil, "ConfigError"
end

function Transactions.purchase(data: ProfileData, ctx: Context, productId: string): (boolean, string, { [string]: any }?)
	local product = findProduct(ctx, productId)
	local price, code = Transactions.quote(data, ctx, productId)
	if not product or not price then
		return false, code, nil
	end
	if not isWholePositive(price) then
		return false, "ConfigError", nil
	end
	if data.currency < price then
		return false, "InsufficientFunds", { price = price }
	end

	-- Commit: deduct and grant together.
	if not Transactions.spend(data, price) then
		return false, "InsufficientFunds", { price = price }
	end
	if product.kind == "Compass" then
		data.compasses[product.compassId] = true
		if data.equippedCompass == "" then
			data.equippedCompass = product.compassId
		end
	elseif product.kind == "ZoneUnlock" then
		data.unlockedZones[product.zoneId] = true
	elseif product.kind == "SpeedUpgrade" then
		data.speedUpgradeLevel += 1
	end
	return true, "Ok", { price = price, kind = product.kind, product = product.displayName }
end

return Transactions
