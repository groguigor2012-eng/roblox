return function(H)
	local SeedShop = H.Module("Server.Classes.SeedShop")
	local HarvestChest = H.Module("Server.Classes.HarvestChest")
	local SeedConfig = H.Module("Shared.Config.SeedConfig")
	local CropConfig = H.Module("Shared.Config.CropConfig")
	local ResultCode = H.Module("Shared.Constants.ResultCode")

	local context = function(wave, level, players)
		return { Wave = wave, ContinueLevel = level or 0, PlayerCount = players or 1 }
	end

	H.test("stock always contains the guaranteed seed and fills the slots", function()
		for seed = 1, 25 do
			local stock = SeedShop.GenerateStock(H.Random.new(seed), context(seed % 12))
			local hasStarFruit = false
			local seen = {}
			for _, entry in stock do
				H.ok(not seen[entry.SeedId], "duplicate seed in stock")
				seen[entry.SeedId] = true
				if entry.SeedId == "NeonStarFruit" then
					hasStarFruit = true
				end
				H.ok(entry.Quantity >= 1 and entry.Price >= SeedConfig.PriceRoundTo)
				H.eq(entry.Price % SeedConfig.PriceRoundTo, 0, "price rounding")
			end
			H.ok(hasStarFruit, "AlwaysStocked seed missing")
			H.ok(#stock <= SeedConfig.SlotCount)
		end
	end)

	H.test("MinWave gates rare seeds", function()
		for seed = 1, 40 do
			for _, entry in SeedShop.GenerateStock(H.Random.new(seed), context(0)) do
				H.ok(SeedConfig.Seeds[entry.SeedId].MinWave == 0, `{entry.SeedId} offered too early`)
			end
		end
	end)

	H.test("prices stay inside the configured variance", function()
		for seed = 1, 40 do
			for _, entry in SeedShop.GenerateStock(H.Random.new(seed), context(12)) do
				local rule = SeedConfig.Seeds[entry.SeedId]
				local base = CropConfig.Get(entry.SeedId).SeedPrice
				H.ok(entry.Price >= base * rule.PriceVariance[1] - SeedConfig.PriceRoundTo)
				H.ok(entry.Price <= base * rule.PriceVariance[2] + SeedConfig.PriceRoundTo)
			end
		end
	end)

	H.test("stock generation is deterministic", function()
		local a = SeedShop.GenerateStock(H.Random.new(99), context(8, 2, 3))
		local b = SeedShop.GenerateStock(H.Random.new(99), context(8, 2, 3))
		H.eq(#a, #b)
		for i = 1, #a do
			H.eq(a[i].SeedId, b[i].SeedId)
			H.eq(a[i].Price, b[i].Price)
			H.eq(a[i].Quantity, b[i].Quantity)
		end
	end)

	H.test("purchases: version, stock and per-player limits", function()
		local shop = SeedShop.new()
		shop:Restock(H.Random.new(5), context(1))
		local entry = shop.Entries[1]
		local ok, code = shop:CheckPurchase(1, entry.SeedId, shop.Version - 1)
		H.ok(not ok)
		H.eq(code, ResultCode.StockChanged)
		ok, code = shop:CheckPurchase(1, "NotASeed", shop.Version)
		H.eq(code, ResultCode.NotFound)

		local quantity = entry.Quantity
		for _ = 1, quantity do
			H.ok((shop:CheckPurchase(1, entry.SeedId, shop.Version)))
			shop:CommitPurchase(1, entry.SeedId)
		end
		ok, code = shop:CheckPurchase(2, entry.SeedId, shop.Version)
		H.eq(code, ResultCode.OutOfStock)

		-- Per-player limits.
		local limited = SeedShop.new()
		limited.Version = 1
		limited.Entries = { { SeedId = "VoidPumpkin", Quantity = 5, Price = 200, PerPlayerLimit = 1 } }
		limited._bySeed = { VoidPumpkin = limited.Entries[1] }
		H.ok((limited:CheckPurchase(7, "VoidPumpkin", 1)))
		limited:CommitPurchase(7, "VoidPumpkin")
		ok, code = limited:CheckPurchase(7, "VoidPumpkin", 1)
		H.eq(code, ResultCode.PurchaseLimit)
		H.ok((limited:CheckPurchase(8, "VoidPumpkin", 1)), "another player is unaffected")
	end)

	H.test("restock resets per-player purchase counts", function()
		local shop = SeedShop.new()
		shop:Restock(H.Random.new(3), context(1))
		local id = shop.Entries[1].SeedId
		shop:CommitPurchase(1, id)
		H.eq(shop:GetPurchased(1, id), 1)
		shop:Restock(H.Random.new(4), context(2))
		H.eq(shop:GetPurchased(1, id), 0)
	end)

	H.test("harvest chest accumulates, pays out with risk bonus and forfeits", function()
		local chest = HarvestChest.new()
		H.ok(chest:Deposit("VoidPumpkin", "Void Pumpkin", "x", 2, 600))
		H.ok(chest:Deposit("NeonStarFruit", "Neon", "x", 3, 40))
		H.ok(not chest:Deposit("Bad", "Bad", "x", -1, 10), "negative quantity rejected")
		H.ok(not chest:Deposit("Bad", "Bad", "x", 1.5, 10), "fractional quantity rejected")
		H.eq(chest:GetTotalValue(), 1320)
		H.eq(chest:ComputePayout(1, 0), 1320)
		H.eq(chest:ComputePayout(1, 0.5), 1980)
		H.eq(chest:GetEntries()[1].ItemId, "VoidPumpkin", "sorted by value")
		chest:Forfeit()
		H.eq(chest:ComputePayout(1, 0.5), 0)
		H.ok(not chest:Deposit("NeonStarFruit", "Neon", "x", 1, 40), "no deposits after forfeit")
	end)
end
