--!strict
-- Shop catalogue. Prices here are what the SERVER charges; the client only displays them.
--
-- kind = "Compass"      grants compassId once
-- kind = "ZoneUnlock"   unlocks zoneId (requires `requires` zone first, if set)
-- kind = "SpeedUpgrade" permanent mount speed level; price = basePrice * priceGrowth^level

export type Product = {
	id: string,
	kind: "Compass" | "ZoneUnlock" | "SpeedUpgrade",
	displayName: string,
	description: string,
	price: number?,
	compassId: string?,
	zoneId: string?,
	requires: string?,
	basePrice: number?,
	priceGrowth: number?,
	maxLevel: number?,
	order: number,
}

local ShopConfig = {}

ShopConfig.Products = {
	{
		id = "BasicCompass",
		kind = "Compass",
		compassId = "BasicCompass",
		displayName = "Wooden Compass",
		description = "Points to the nearest egg within 500 studs.",
		price = 100,
		order = 1,
	},
	{
		id = "ExplorerCompass",
		kind = "Compass",
		compassId = "ExplorerCompass",
		displayName = "Explorer's Compass",
		description = "Tracks eggs up to 1500 studs away.",
		price = 750,
		order = 2,
	},
	{
		id = "PrismCompass",
		kind = "Compass",
		compassId = "PrismCompass",
		displayName = "Prism Compass",
		description = "Only tracks Rare or better eggs, anywhere on the map.",
		price = 2500,
		order = 3,
	},
	{
		id = "UnlockLake",
		kind = "ZoneUnlock",
		zoneId = "Lake",
		displayName = "Moonlit Lake Pass",
		description = "Hatch eggs and collect Moon Pearls at the lake.",
		price = 600,
		order = 4,
	},
	{
		id = "UnlockPeaks",
		kind = "ZoneUnlock",
		zoneId = "Peaks",
		requires = "Lake",
		displayName = "Storm Peaks Pass",
		description = "The highest eggs and rarest items. Best reached by air.",
		price = 1800,
		order = 5,
	},
	{
		id = "SpeedUpgrade",
		kind = "SpeedUpgrade",
		displayName = "Saddle Upgrade",
		description = "Permanently increases every mount's speed.",
		basePrice = 300,
		priceGrowth = 1.8,
		maxLevel = 5,
		order = 6,
	},
} :: { Product }

function ShopConfig.get(productId: string): Product?
	for _, product in ShopConfig.Products do
		if product.id == productId then
			return product
		end
	end
	return nil
end

-- Price of the next speed upgrade level, or nil when maxed.
function ShopConfig.speedUpgradePrice(product: Product, currentLevel: number): number?
	local maxLevel = product.maxLevel or 0
	if currentLevel >= maxLevel then
		return nil
	end
	local base = product.basePrice or 0
	local growth = product.priceGrowth or 1
	return math.floor(base * growth ^ currentLevel + 0.5)
end

return ShopConfig
