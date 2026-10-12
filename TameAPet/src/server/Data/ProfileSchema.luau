--!strict
-- The persistent player profile: types, defaults and repair of invalid values.
--
-- Pets live in exactly one canonical collection (`pets`, keyed by unique pet id). Inventory
-- tabs, the taming list and the equipped pet are all derived from it.

export type PetStatus = "Untamed" | "Tamed"

export type PetRecord = {
	id: string,
	species: string,
	rarity: string, -- rarity of the species at the time it was hatched
	eggTier: string, -- egg tier it hatched from (defines its displayed odds)
	status: PetStatus,
	acquiredAt: number, -- os.time()
	tamedAt: number, -- 0 while untamed
}

export type ProfileStats = {
	eggsHatched: number,
	itemsCollected: number,
	petsTamed: number,
	coinsEarned: number,
}

export type ProfileData = {
	schemaVersion: number,
	currency: number,
	compasses: { [string]: boolean }, -- owned compass ids
	equippedCompass: string, -- "" = none
	pets: { [string]: PetRecord },
	items: { [string]: number }, -- item id -> quantity (> 0)
	equippedPetId: string, -- "" = none; must reference a Tamed pet
	speedUpgradeLevel: number,
	unlockedZones: { [string]: boolean },
	stats: ProfileStats,
	flags: { [string]: boolean },
	createdAt: number,
	lastJoinAt: number,
}

local ProfileSchema = {}

ProfileSchema.CURRENT_VERSION = 1
ProfileSchema.PET_STATUSES = { Untamed = true, Tamed = true }

function ProfileSchema.template(startingCurrency: number, defaultZones: { string }): ProfileData
	local zones = {}
	for _, zoneId in defaultZones do
		zones[zoneId] = true
	end
	return {
		schemaVersion = ProfileSchema.CURRENT_VERSION,
		currency = startingCurrency,
		compasses = {},
		equippedCompass = "",
		pets = {},
		items = {},
		equippedPetId = "",
		speedUpgradeLevel = 0,
		unlockedZones = zones,
		stats = { eggsHatched = 0, itemsCollected = 0, petsTamed = 0, coinsEarned = 0 },
		flags = {},
		createdAt = 0,
		lastJoinAt = 0,
	}
end

local function finiteNumber(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function wholeNonNegative(value: any, maxValue: number): number
	if not finiteNumber(value) then
		return 0
	end
	return math.clamp(math.floor(value), 0, maxValue)
end

export type SanitizeContext = {
	knownSpecies: { [string]: any },
	knownCompasses: { [string]: any },
	maxCurrency: number,
	maxItemStack: number,
	maxSpeedLevel: number,
}

-- Repairs values that can never be valid. Unknown species/compass/item ids are KEPT (they
-- may come back in a future config) but can't be equipped. Returns human-readable notes for
-- every repair made, for logging.
function ProfileSchema.sanitize(data: ProfileData, ctx: SanitizeContext): { string }
	local notes: { string } = {}
	local function note(text: string)
		table.insert(notes, text)
	end

	local currency = wholeNonNegative(data.currency, ctx.maxCurrency)
	if currency ~= data.currency then
		note(`currency {tostring(data.currency)} -> {currency}`)
		data.currency = currency
	end

	if type(data.compasses) ~= "table" then
		data.compasses = {}
		note("compasses reset (not a table)")
	end
	for compassId, owned in data.compasses do
		if type(compassId) ~= "string" or owned ~= true then
			data.compasses[compassId] = nil
			note(`removed invalid compass entry {tostring(compassId)}`)
		end
	end
	if type(data.equippedCompass) ~= "string" then
		data.equippedCompass = ""
	end
	if data.equippedCompass ~= "" and (not data.compasses[data.equippedCompass] or not ctx.knownCompasses[data.equippedCompass]) then
		note(`unequipped compass {data.equippedCompass}`)
		data.equippedCompass = ""
	end

	if type(data.pets) ~= "table" then
		data.pets = {}
		note("pets reset (not a table)")
	end
	for petId, pet in data.pets do
		if type(petId) ~= "string" or type(pet) ~= "table" or type(pet.species) ~= "string" then
			data.pets[petId] = nil
			note(`removed malformed pet {tostring(petId)}`)
			continue
		end
		pet.id = petId
		if not ProfileSchema.PET_STATUSES[pet.status] then
			note(`pet {petId} had status {tostring(pet.status)}; set to Untamed`)
			pet.status = "Untamed"
		end
		if type(pet.rarity) ~= "string" then
			local species = ctx.knownSpecies[pet.species]
			pet.rarity = if species then species.rarity else "Common"
		end
		if type(pet.eggTier) ~= "string" then
			pet.eggTier = pet.rarity
		end
		if not finiteNumber(pet.acquiredAt) then
			pet.acquiredAt = 0
		end
		if not finiteNumber(pet.tamedAt) then
			pet.tamedAt = 0
		end
	end

	if type(data.items) ~= "table" then
		data.items = {}
		note("items reset (not a table)")
	end
	for itemId, quantity in data.items do
		local fixed = wholeNonNegative(quantity, ctx.maxItemStack)
		if type(itemId) ~= "string" or fixed <= 0 then
			data.items[itemId] = nil
		elseif fixed ~= quantity then
			note(`item {itemId} quantity {tostring(quantity)} -> {fixed}`)
			data.items[itemId] = fixed
		end
	end

	if type(data.equippedPetId) ~= "string" then
		data.equippedPetId = ""
	end
	if data.equippedPetId ~= "" then
		local pet = data.pets[data.equippedPetId]
		if not pet or pet.status ~= "Tamed" or not ctx.knownSpecies[pet.species] then
			note(`unequipped pet {data.equippedPetId}`)
			data.equippedPetId = ""
		end
	end

	data.speedUpgradeLevel = wholeNonNegative(data.speedUpgradeLevel, ctx.maxSpeedLevel)

	if type(data.unlockedZones) ~= "table" then
		data.unlockedZones = {}
	end
	if type(data.stats) ~= "table" then
		data.stats = { eggsHatched = 0, itemsCollected = 0, petsTamed = 0, coinsEarned = 0 }
	end
	for key, value in data.stats do
		if not finiteNumber(value) then
			(data.stats :: any)[key] = 0
		end
	end
	if type(data.flags) ~= "table" then
		data.flags = {}
	end

	return notes
end

return ProfileSchema
