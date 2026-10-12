-- Weighted RNG, odds display, formatting and the config cross-check.
local describe, it, expect = T.describe, T.it, T.expect

local WeightedRandom = T.load("ReplicatedStorage/Shared/WeightedRandom")
local Odds = T.load("ReplicatedStorage/Shared/Odds")
local Format = T.load("ReplicatedStorage/Shared/Format")
local ConfigValidator = T.load("ReplicatedStorage/Shared/ConfigValidator")
local EggConfig = T.load("ReplicatedStorage/Config/EggConfig")

local function configs()
	return {
		Rarity = T.load("ReplicatedStorage/Config/RarityConfig"),
		Pets = T.load("ReplicatedStorage/Config/PetConfig"),
		Items = T.load("ReplicatedStorage/Config/ItemConfig"),
		Eggs = EggConfig,
		Zones = T.load("ReplicatedStorage/Config/ZoneConfig"),
		Compasses = T.load("ReplicatedStorage/Config/CompassConfig"),
		Shop = T.load("ReplicatedStorage/Config/ShopConfig"),
	}
end

describe("WeightedRandom", function()
	local pool = { A = 1, B = 3 }
	it("maps rolls onto cumulative weights in sorted key order", function()
		expect(WeightedRandom.pickWithRoll(pool, 0)).toBe("A")
		expect(WeightedRandom.pickWithRoll(pool, 0.2499)).toBe("A")
		expect(WeightedRandom.pickWithRoll(pool, 0.25)).toBe("B")
		expect(WeightedRandom.pickWithRoll(pool, 0.9999)).toBe("B")
	end)
	it("ignores invalid weights and returns nil for empty pools", function()
		expect(WeightedRandom.pickWithRoll({ A = 0, B = -1, C = 0 / 0 }, 0.5)).toBe(nil)
		expect(WeightedRandom.pickWithRoll({ A = 0 / 0, B = 2 }, 0.1)).toBe("B")
	end)
	it("matches configured probabilities over many rolls", function()
		local rng = Random.new(42)
		local counts = { A = 0, B = 0 }
		for _ = 1, 40000 do
			local key = WeightedRandom.pick(pool, rng)
			counts[key] += 1
		end
		expect(counts.A / 40000).toBeNear(0.25, 0.015)
	end)
end)

describe("Odds", function()
	it("shows exact 1 in N for each egg pool", function()
		expect(Odds.text(EggConfig.Tiers.Common.pool, "MoonTurtle")).toBe("1 in 50")
		expect(Odds.text(EggConfig.Tiers.Legendary.pool, "SkyPegasus")).toBe("1 in 1,000")
		expect(Odds.text(EggConfig.Tiers.Secret.pool, "CelestialDragon")).toBe("1 in 100")
	end)
	it("never rounds non-integer odds into a false integer", function()
		expect(Odds.text({ A = 2, B = 3 }, "A")).toBe("1 in 2.5")
		expect(Odds.text({ A = 1, B = 1, C = 1 }, "A")).toBe("1 in 3")
		expect(Odds.text({ A = 3, B = 4000 }, "A")).toBe("~1 in 1,334")
	end)
	it("handles guaranteed and missing entries", function()
		expect(Odds.text({ A = 5 }, "A")).toBe("Guaranteed")
		expect(Odds.text({ A = 5 }, "B")).toBe(nil)
	end)
end)

describe("Format", function()
	it("formats numbers and distances", function()
		expect(Format.commas(1234567)).toBe("1,234,567")
		expect(Format.commas(999)).toBe("999")
		expect(Format.distance(1500, 1000, "studs")).toBe("1.5k studs")
		expect(Format.distance(42.4, 1000, "studs")).toBe("42 studs")
	end)
end)

describe("ConfigValidator", function()
	it("accepts the shipped configuration", function()
		local problems = ConfigValidator.validate(configs())
		if #problems > 0 then
			error(table.concat(problems, "\n"))
		end
	end)
	it("reports broken references", function()
		local c = configs()
		local brokenEggs = { Tiers = table.clone(c.Eggs.Tiers) }
		brokenEggs.Tiers.Common = table.clone(brokenEggs.Tiers.Common)
		brokenEggs.Tiers.Common.pool = { NotAPet = 5 }
		c.Eggs = brokenEggs
		local problems = ConfigValidator.validate(c)
		expect(#problems >= 1).toBeTruthy()
	end)
	it("maps the five required pets to their items", function()
		local pets = configs().Pets.Species
		expect(pets.SkyPegasus.requiredItem).toBe("GoldenApple")
		expect(pets.EmberWolf.requiredItem).toBe("PhoenixFeather")
		expect(pets.MoonTurtle.requiredItem).toBe("MoonPearl")
		expect(pets.ShadowFox.requiredItem).toBe("VoidCrystal")
		expect(pets.StormGriffin.requiredItem).toBe("StormCore")
	end)
end)
