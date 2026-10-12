--!strict
-- Cross-checks the configuration modules so a typo (an egg pool naming a species that does
-- not exist, a pet requiring an unknown item...) produces a clear startup warning instead
-- of a runtime failure. Pure: returns a list of problems, never throws.

export type Configs = {
	Rarity: any,
	Pets: any,
	Items: any,
	Eggs: any,
	Zones: any,
	Compasses: any,
	Shop: any,
}

local ConfigValidator = {}

local function positive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value < math.huge
end

function ConfigValidator.validate(c: Configs): { string }
	local problems: { string } = {}
	local function report(message: string)
		table.insert(problems, message)
	end

	local rarities = c.Rarity.Tiers
	for _, id in c.Rarity.Order do
		if not rarities[id] then
			report(`RarityConfig.Order lists "{id}" but RarityConfig.Tiers has no entry for it`)
		end
	end

	-- Pets
	for speciesId, species in c.Pets.Species do
		if not rarities[species.rarity] then
			report(`Pet "{speciesId}" has unknown rarity "{tostring(species.rarity)}"`)
		end
		if not c.Items.Items[species.requiredItem] then
			report(`Pet "{speciesId}" requires unknown taming item "{tostring(species.requiredItem)}"`)
		end
		if not positive(species.baseSpeed) or not positive(species.tierMultiplier) then
			report(`Pet "{speciesId}" needs positive baseSpeed and tierMultiplier`)
		end
		local hasFlight = table.find(species.abilities, "Flight") ~= nil
		if hasFlight and species.mountType ~= "Flying" then
			report(`Pet "{speciesId}" has the Flight ability but mountType "{species.mountType}" (must be "Flying")`)
		end
		if species.mountType == "Flying" and not hasFlight then
			report(`Pet "{speciesId}" is a Flying mount without the "Flight" ability; it will not be able to fly`)
		end
	end

	-- Items
	local zoneIds: { [string]: boolean } = {}
	for _, zone in c.Zones.Zones do
		if zoneIds[zone.id] then
			report(`Zone id "{zone.id}" is defined twice`)
		end
		zoneIds[zone.id] = true
	end
	for itemId, item in c.Items.Items do
		if not rarities[item.rarity] then
			report(`Item "{itemId}" has unknown rarity "{tostring(item.rarity)}"`)
		end
		for _, zoneId in item.spawn.zones do
			if not zoneIds[zoneId] then
				report(`Item "{itemId}" spawns in unknown zone "{zoneId}"`)
			end
		end
		if not positive(item.spawn.interval) or not positive(item.spawn.despawnSeconds) then
			report(`Item "{itemId}" needs positive spawn.interval and spawn.despawnSeconds`)
		end
	end

	-- Eggs
	for tierId, tier in c.Eggs.Tiers do
		if not rarities[tierId] then
			report(`Egg tier "{tierId}" is not a rarity in RarityConfig`)
		end
		local any = false
		for speciesId, weight in tier.pool do
			if not c.Pets.Species[speciesId] then
				report(`Egg tier "{tierId}" pool contains unknown species "{speciesId}"`)
			elseif not positive(weight) then
				report(`Egg tier "{tierId}" has a non-positive weight for "{speciesId}"`)
			else
				any = true
			end
		end
		if not any then
			report(`Egg tier "{tierId}" has no valid species in its pool`)
		end
	end

	-- Zones
	for _, zone in c.Zones.Zones do
		local eggs = zone.eggs
		for tierId, weight in eggs.weights do
			if not c.Eggs.Tiers[tierId] then
				report(`Zone "{zone.id}" spawns unknown egg tier "{tierId}"`)
			elseif not positive(weight) then
				report(`Zone "{zone.id}" has a non-positive weight for egg tier "{tierId}"`)
			end
		end
		if eggs.minActive > eggs.maxActive then
			report(`Zone "{zone.id}" has eggs.minActive > eggs.maxActive`)
		end
		if not positive(eggs.spawnInterval) or not positive(eggs.despawnSeconds) then
			report(`Zone "{zone.id}" needs positive eggs.spawnInterval and eggs.despawnSeconds`)
		end
		if zone.unlock ~= nil and not zoneIds[zone.unlock] then
			report(`Zone "{zone.id}" requires unknown unlock "{zone.unlock}"`)
		end
	end
	for _, zoneId in c.Zones.DefaultUnlocked do
		if not zoneIds[zoneId] then
			report(`ZoneConfig.DefaultUnlocked contains unknown zone "{zoneId}"`)
		end
	end

	-- Compasses
	for compassId, compass in c.Compasses.Compasses do
		if not rarities[compass.minTier] then
			report(`Compass "{compassId}" has unknown minTier "{tostring(compass.minTier)}"`)
		end
		if not positive(compass.maxRange) then
			report(`Compass "{compassId}" needs a positive maxRange`)
		end
	end

	-- Shop
	local productIds: { [string]: boolean } = {}
	for _, product in c.Shop.Products do
		if productIds[product.id] then
			report(`Shop product id "{product.id}" is defined twice`)
		end
		productIds[product.id] = true
		if product.kind == "Compass" then
			if not c.Compasses.Compasses[product.compassId or ""] then
				report(`Shop product "{product.id}" grants unknown compass "{tostring(product.compassId)}"`)
			end
			if not positive(product.price) then
				report(`Shop product "{product.id}" needs a positive price`)
			end
		elseif product.kind == "ZoneUnlock" then
			if not zoneIds[product.zoneId or ""] then
				report(`Shop product "{product.id}" unlocks unknown zone "{tostring(product.zoneId)}"`)
			end
			if product.requires ~= nil and not zoneIds[product.requires] then
				report(`Shop product "{product.id}" requires unknown zone "{product.requires}"`)
			end
			if not positive(product.price) then
				report(`Shop product "{product.id}" needs a positive price`)
			end
		elseif product.kind == "SpeedUpgrade" then
			if not positive(product.basePrice) or not positive(product.priceGrowth) or not positive(product.maxLevel) then
				report(`Shop product "{product.id}" needs positive basePrice, priceGrowth and maxLevel`)
			end
		else
			report(`Shop product "{product.id}" has unknown kind "{tostring(product.kind)}"`)
		end
	end

	return problems
end

return ConfigValidator
