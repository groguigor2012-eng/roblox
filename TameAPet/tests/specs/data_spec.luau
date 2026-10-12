-- Profile schema, migrations, sanitising, transactions (taming, purchases, inventory) and
-- the client view.
local describe, it, expect = T.describe, T.it, T.expect

local ProfileSchema = T.load("ServerScriptService/Data/ProfileSchema")
local Migrations = T.load("ServerScriptService/Data/Migrations")
local Transactions = T.load("ServerScriptService/Data/Transactions")
local ProfileView = T.load("ServerScriptService/Data/ProfileView")
local MountStats = T.load("ServerScriptService/Services/MountStats")
local PetConfig = T.load("ReplicatedStorage/Config/PetConfig")
local ItemConfig = T.load("ReplicatedStorage/Config/ItemConfig")
local CompassConfig = T.load("ReplicatedStorage/Config/CompassConfig")
local ShopConfig = T.load("ReplicatedStorage/Config/ShopConfig")
local ZoneConfig = T.load("ReplicatedStorage/Config/ZoneConfig")
local MountConfig = T.load("ReplicatedStorage/Config/MountConfig")

local idCounter = 0
local function context(overrides)
	local ctx = {
		Pets = PetConfig.Species,
		Items = ItemConfig.Items,
		Compasses = CompassConfig.Compasses,
		Products = ShopConfig.Products,
		Zones = ZoneConfig.Zones,
		maxPets = 3,
		maxItemStack = 5,
		maxCurrency = 1e6,
		speedUpgradePrice = ShopConfig.speedUpgradePrice,
		now = function()
			return 1000
		end,
		newId = function()
			idCounter += 1
			return `pet-{idCounter}`
		end,
	}
	for k, v in overrides or {} do
		ctx[k] = v
	end
	return ctx
end

local function fresh(currency: number?)
	return ProfileSchema.template(currency or 300, ZoneConfig.DefaultUnlocked)
end

describe("Migrations", function()
	it("leaves current profiles alone", function()
		local data = fresh()
		local result, version = Migrations.run(data)
		expect(result).toBe("Ok")
		expect(version).toBe(ProfileSchema.CURRENT_VERSION)
	end)
	it("upgrades unversioned legacy profiles", function()
		local legacy = { coins = 77, pets = { { id = "a", species = "MeadowBunny", status = "Tamed" } } }
		expect(Migrations.run(legacy)).toBe("Ok")
		expect(legacy.currency).toBe(77)
		expect(legacy.coins).toBe(nil)
		expect(legacy.pets.a.species).toBe("MeadowBunny")
		expect(legacy.schemaVersion).toBe(ProfileSchema.CURRENT_VERSION)
	end)
	it("refuses profiles written by a newer server", function()
		local data = fresh()
		data.schemaVersion = ProfileSchema.CURRENT_VERSION + 1
		expect(Migrations.run(data)).toBe("Newer")
		expect(data.schemaVersion).toBe(ProfileSchema.CURRENT_VERSION + 1)
	end)
end)

describe("ProfileSchema.sanitize", function()
	local sanitizeCtx = {
		knownSpecies = PetConfig.Species,
		knownCompasses = CompassConfig.Compasses,
		maxCurrency = 1e6,
		maxItemStack = 99,
		maxSpeedLevel = 5,
	}
	it("repairs impossible values without deleting unknown content", function()
		local data = fresh()
		data.currency = -50
		data.items = { MoonPearl = 2.7, StormCore = -3 }
		data.pets = {
			p1 = { species = "EmberWolf", status = "Flying", rarity = "Rare", eggTier = "Rare", acquiredAt = 1, tamedAt = 0 },
			p2 = { species = "RemovedSpecies", status = "Tamed", rarity = "Epic", eggTier = "Epic", acquiredAt = 1, tamedAt = 1 },
		}
		data.equippedPetId = "p1"
		data.equippedCompass = "BasicCompass" -- not owned
		ProfileSchema.sanitize(data, sanitizeCtx)
		expect(data.currency).toBe(0)
		expect(data.items.MoonPearl).toBe(2)
		expect(data.items.StormCore).toBe(nil)
		expect(data.pets.p1.status).toBe("Untamed")
		expect(data.pets.p2 ~= nil).toBeTruthy()
		expect(data.equippedPetId).toBe("") -- p1 is untamed after repair
		expect(data.equippedCompass).toBe("")
	end)
end)

describe("Transactions: taming", function()
	it("consumes exactly one item and marks the pet Tamed", function()
		local data, ctx = fresh(), context()
		local pet = Transactions.addPet(data, ctx, "EmberWolf", "Rare")
		Transactions.addItem(data, ctx, "PhoenixFeather", 2)
		local ok, code = Transactions.tamePet(data, ctx, pet.id)
		expect(ok).toBe(true)
		expect(code).toBe("Ok")
		expect(data.pets[pet.id].status).toBe("Tamed")
		expect(data.items.PhoenixFeather).toBe(1)
	end)
	it("fails without the item and changes nothing", function()
		local data, ctx = fresh(), context()
		local pet = Transactions.addPet(data, ctx, "SkyPegasus", "Mythical")
		Transactions.addItem(data, ctx, "StormCore", 1) -- wrong item
		local ok, code = Transactions.tamePet(data, ctx, pet.id)
		expect(ok).toBe(false)
		expect(code).toBe("MissingItem")
		expect(data.pets[pet.id].status).toBe("Untamed")
		expect(data.items.StormCore).toBe(1)
	end)
	it("cannot tame the same pet twice or spend one item on two pets", function()
		local data, ctx = fresh(), context()
		local a = Transactions.addPet(data, ctx, "MoonTurtle", "Common")
		local b = Transactions.addPet(data, ctx, "MoonTurtle", "Common")
		Transactions.addItem(data, ctx, "MoonPearl", 1)
		expect(Transactions.tamePet(data, ctx, a.id)).toBe(true)
		local again, againCode = Transactions.tamePet(data, ctx, a.id)
		expect(again).toBe(false)
		expect(againCode).toBe("AlreadyTamed")
		local second, secondCode = Transactions.tamePet(data, ctx, b.id)
		expect(second).toBe(false)
		expect(secondCode).toBe("MissingItem")
		expect(data.items.MoonPearl).toBe(nil)
		expect(data.pets[b.id].status).toBe("Untamed")
	end)
	it("rejects pets the player does not own", function()
		local data, ctx = fresh(), context()
		Transactions.addItem(data, ctx, "MoonPearl", 1)
		local ok, code = Transactions.tamePet(data, ctx, "someone-elses-pet")
		expect(ok).toBe(false)
		expect(code).toBe("NotOwned")
		expect(data.items.MoonPearl).toBe(1)
	end)
end)

describe("Transactions: inventory", function()
	it("enforces the pet limit", function()
		local data, ctx = fresh(), context({ maxPets = 2 })
		expect(Transactions.addPet(data, ctx, "MeadowBunny", "Common") ~= nil).toBeTruthy()
		expect(Transactions.addPet(data, ctx, "MeadowBunny", "Common") ~= nil).toBeTruthy()
		local pet, code = Transactions.addPet(data, ctx, "MeadowBunny", "Common")
		expect(pet).toBe(nil)
		expect(code).toBe("InventoryFull")
	end)
	it("stores duplicate species as separate pets", function()
		local data, ctx = fresh(), context()
		local a = Transactions.addPet(data, ctx, "MeadowBunny", "Common")
		local b = Transactions.addPet(data, ctx, "MeadowBunny", "Common")
		expect(a.id ~= b.id).toBeTruthy()
		expect(Transactions.countPets(data)).toBe(2)
	end)
	it("caps item stacks and rejects unknown items", function()
		local data, ctx = fresh(), context({ maxItemStack = 5 })
		local added = Transactions.addItem(data, ctx, "LuckyClover", 9)
		expect(added).toBe(5)
		local none, code = Transactions.addItem(data, ctx, "LuckyClover", 1)
		expect(none).toBe(0)
		expect(code).toBe("InventoryFull")
		expect((Transactions.addItem(data, ctx, "FreeMoney", 1))).toBe(0)
	end)
	it("only equips tamed pets", function()
		local data, ctx = fresh(), context()
		local pet = Transactions.addPet(data, ctx, "MeadowBunny", "Common")
		local ok, code = Transactions.equipPet(data, ctx, pet.id)
		expect(ok).toBe(false)
		expect(code).toBe("NotTamed")
		data.pets[pet.id].status = "Tamed"
		expect(Transactions.equipPet(data, ctx, pet.id)).toBe(true)
		expect(data.equippedPetId).toBe(pet.id)
	end)
end)

describe("Transactions: shop", function()
	it("rejects purchases the player cannot afford without changing anything", function()
		local data, ctx = fresh(50), context()
		local ok, code = Transactions.purchase(data, ctx, "BasicCompass")
		expect(ok).toBe(false)
		expect(code).toBe("InsufficientFunds")
		expect(data.currency).toBe(50)
		expect(data.compasses.BasicCompass).toBe(nil)
	end)
	it("buys and auto-equips the first compass, once", function()
		local data, ctx = fresh(300), context()
		expect(Transactions.purchase(data, ctx, "BasicCompass")).toBe(true)
		expect(data.currency).toBe(200)
		expect(data.equippedCompass).toBe("BasicCompass")
		local again, code = Transactions.purchase(data, ctx, "BasicCompass")
		expect(again).toBe(false)
		expect(code).toBe("AlreadyOwned")
		expect(data.currency).toBe(200)
	end)
	it("respects zone unlock order", function()
		local data, ctx = fresh(10000), context()
		local ok, code = Transactions.purchase(data, ctx, "UnlockPeaks")
		expect(ok).toBe(false)
		expect(code).toBe("Locked")
		expect(Transactions.purchase(data, ctx, "UnlockLake")).toBe(true)
		expect(Transactions.purchase(data, ctx, "UnlockPeaks")).toBe(true)
		expect(data.unlockedZones.Peaks).toBe(true)
	end)
	it("prices speed upgrades by level and stops at the max", function()
		local data, ctx = fresh(1e6), context()
		local product = ShopConfig.get("SpeedUpgrade")
		expect(Transactions.quote(data, ctx, "SpeedUpgrade")).toBe(300)
		for _ = 1, product.maxLevel do
			expect(Transactions.purchase(data, ctx, "SpeedUpgrade")).toBe(true)
		end
		local ok, code = Transactions.purchase(data, ctx, "SpeedUpgrade")
		expect(ok).toBe(false)
		expect(code).toBe("Maxed")
		expect(data.speedUpgradeLevel).toBe(product.maxLevel)
	end)
	it("rejects unknown products", function()
		local data, ctx = fresh(1e6), context()
		local ok, code = Transactions.purchase(data, ctx, "FreeDragon")
		expect(ok).toBe(false)
		expect(code).toBe("NotFound")
		expect(data.currency).toBe(1e6)
	end)
	it("never accepts negative or fractional currency changes", function()
		local data, ctx = fresh(100), context()
		expect(Transactions.addCurrency(data, ctx, -500)).toBe(0)
		expect(Transactions.addCurrency(data, ctx, 1.5)).toBe(0)
		expect(Transactions.spend(data, -10)).toBe(false)
		expect(data.currency).toBe(100)
	end)
end)

describe("ProfileView", function()
	it("derives tabs from the canonical pet list", function()
		local data, ctx = fresh(), context()
		local wolf = Transactions.addPet(data, ctx, "EmberWolf", "Rare")
		Transactions.addPet(data, ctx, "MeadowBunny", "Common")
		data.pets.ghost = { id = "ghost", species = "Removed", rarity = "Epic", eggTier = "Epic", status = "Tamed", acquiredAt = 0, tamedAt = 0 }
		local view = ProfileView.build(data, {
			Pets = PetConfig.Species,
			Items = ItemConfig.Items,
			rarityRank = T.load("ReplicatedStorage/Config/RarityConfig").rank,
			oddsText = function()
				return "odds"
			end,
			computeSpeed = function(species, level)
				return MountStats.computeSpeed(species, level, MountConfig)
			end,
			canFly = MountStats.canFly,
			maxPets = 150,
		})
		expect(#view.pets).toBe(2) -- unknown species hidden but still counted
		expect(view.petCount).toBe(3)
		expect(view.pets[1].id).toBe(wolf.id) -- rarest first
		local needed = 0
		for _, item in view.items do
			if item.quantity == 0 and item.neededBy > 0 then
				needed += 1
			end
		end
		expect(needed).toBe(2) -- PhoenixFeather and LuckyClover listed at 0
	end)
end)
