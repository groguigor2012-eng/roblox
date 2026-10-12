--!strict
-- Builds the read-only snapshot of a profile that is sent to its owner's client. The client
-- renders from this and never sends any of it back as authoritative input.

local ProfileSchema = require(script.Parent.ProfileSchema)

type ProfileData = ProfileSchema.ProfileData

export type PetView = {
	id: string,
	species: string,
	displayName: string,
	rarity: string,
	eggTier: string,
	status: ProfileSchema.PetStatus,
	acquiredAt: number,
	requiredItem: string,
	requiredItemName: string,
	hasRequiredItem: boolean,
	oddsText: string,
	speed: number,
	canFly: boolean,
	abilities: { string },
	equipped: boolean,
}

export type ItemView = {
	id: string,
	displayName: string,
	rarity: string,
	quantity: number,
	neededBy: number, -- untamed pets waiting for this item
}

export type ProfileViewData = {
	currency: number,
	pets: { PetView },
	petCount: number,
	maxPets: number,
	items: { ItemView },
	compasses: { string },
	equippedCompass: string,
	equippedPetId: string,
	speedUpgradeLevel: number,
	unlockedZones: { string },
	stats: { [string]: number },
}

export type ViewContext = {
	Pets: { [string]: any },
	Items: { [string]: any },
	rarityRank: (string) -> number,
	oddsText: (eggTier: string, speciesId: string) -> string,
	computeSpeed: (species: any, upgradeLevel: number) -> number,
	canFly: (species: any) -> boolean,
	maxPets: number,
}

local ProfileView = {}

function ProfileView.build(data: ProfileData, ctx: ViewContext): ProfileViewData
	local pets: { PetView } = {}
	local neededBy: { [string]: number } = {}
	local petCount = 0

	for petId, pet in data.pets do
		petCount += 1
		local species = ctx.Pets[pet.species]
		if not species then
			continue -- unknown species (removed from config) stays saved but hidden
		end
		local item = ctx.Items[species.requiredItem]
		if pet.status == "Untamed" then
			neededBy[species.requiredItem] = (neededBy[species.requiredItem] or 0) + 1
		end
		table.insert(pets, {
			id = petId,
			species = pet.species,
			displayName = species.displayName,
			rarity = pet.rarity,
			eggTier = pet.eggTier,
			status = pet.status,
			acquiredAt = pet.acquiredAt,
			requiredItem = species.requiredItem,
			requiredItemName = if item then item.displayName else species.requiredItem,
			hasRequiredItem = (data.items[species.requiredItem] or 0) > 0,
			oddsText = ctx.oddsText(pet.eggTier, pet.species),
			speed = math.floor(ctx.computeSpeed(species, data.speedUpgradeLevel) + 0.5),
			canFly = ctx.canFly(species),
			abilities = table.clone(species.abilities),
			equipped = data.equippedPetId == petId,
		})
	end

	-- Equipped first, then rarest, then newest.
	table.sort(pets, function(a, b)
		if a.equipped ~= b.equipped then
			return a.equipped
		end
		local ra, rb = ctx.rarityRank(a.rarity), ctx.rarityRank(b.rarity)
		if ra ~= rb then
			return ra > rb
		end
		if a.acquiredAt ~= b.acquiredAt then
			return a.acquiredAt > b.acquiredAt
		end
		return a.id < b.id
	end)

	local items: { ItemView } = {}
	local listed: { [string]: boolean } = {}
	local function addItem(itemId: string, quantity: number)
		local item = ctx.Items[itemId]
		if not item or listed[itemId] then
			return
		end
		listed[itemId] = true
		table.insert(items, {
			id = itemId,
			displayName = item.displayName,
			rarity = item.rarity,
			quantity = quantity,
			neededBy = neededBy[itemId] or 0,
		})
	end
	for itemId, quantity in data.items do
		addItem(itemId, quantity)
	end
	-- Items the player still needs but has none of are listed too, at quantity 0.
	for itemId in neededBy do
		addItem(itemId, 0)
	end
	table.sort(items, function(a, b)
		local ra, rb = ctx.rarityRank(a.rarity), ctx.rarityRank(b.rarity)
		if ra ~= rb then
			return ra > rb
		end
		return a.id < b.id
	end)

	local compasses = {}
	for compassId in data.compasses do
		table.insert(compasses, compassId)
	end
	table.sort(compasses)

	local zones = {}
	for zoneId in data.unlockedZones do
		table.insert(zones, zoneId)
	end
	table.sort(zones)

	return {
		currency = data.currency,
		pets = pets,
		petCount = petCount,
		maxPets = ctx.maxPets,
		items = items,
		compasses = compasses,
		equippedCompass = data.equippedCompass,
		equippedPetId = data.equippedPetId,
		speedUpgradeLevel = data.speedUpgradeLevel,
		unlockedZones = zones,
		stats = table.clone(data.stats) :: any,
	}
end

return ProfileView
