local roblox = require("@lune/roblox")
local task = require("@lune/task")
local Vector3, CFrame = roblox.Vector3, roblox.CFrame

return function(H)
	local Registry = H.Module("Server.Registry")
	local ResultCode = H.Module("Shared.Constants.ResultCode")
	local ClassConfig = H.Module("Shared.Config.ClassConfig")
	local EconomyConfig = H.Module("Shared.Config.EconomyConfig")
	local ProfileTemplate = H.Module("Server.Data.ProfileTemplate")
	local PlayersService = H.Service("Players")

	local noop = function() end
	Registry.RemoteService = {
		FireClient = noop,
		FireClients = noop,
		OnInvoke = noop,
		OnEvent = noop,
		ReportViolation = noop,
	}

	local DataService = H.Module("Server.Services.DataService")
	Registry.DataService = DataService
	DataService:Init()

	local nextUserId = 100
	local function newPlayer()
		nextUserId += 1
		local attributes = {}
		return {
			UserId = nextUserId,
			Name = `Player{nextUserId}`,
			DisplayName = `Player{nextUserId}`,
			Parent = PlayersService,
			SetAttribute = function(_, key, value)
				attributes[key] = value
			end,
			GetAttribute = function(_, key)
				return attributes[key]
			end,
			Kick = noop,
		}
	end

	local function loadedPlayer()
		local player = newPlayer()
		local ok, problem = DataService:LoadProfileAsync(player)
		assert(ok, problem)
		return player
	end

	H.test("profiles load from the template and candies are validated", function()
		local player = loadedPlayer()
		H.eq(DataService:GetCandies(player), ProfileTemplate.Candies)
		H.ok(not DataService:AddCandies(player, -5), "negative grant")
		H.ok(not DataService:AddCandies(player, 1.5), "fractional grant")
		H.ok(not DataService:AddCandies(player, 0 / 0), "NaN grant")
		H.ok(DataService:AddCandies(player, 30))
		H.eq(DataService:GetCandies(player), ProfileTemplate.Candies + 30)
		H.ok(not DataService:SpendCandies(player, 10_000), "cannot overspend")
		H.eq(DataService:GetCandies(player), ProfileTemplate.Candies + 30)
	end)

	H.test("failed mutations roll back", function()
		local player = loadedPlayer()
		local before = DataService:GetCandies(player)
		local ok = DataService:Update(player, function(data)
			data.Candies = 0
			error("simulated bug mid-transaction")
		end)
		H.ok(not ok)
		H.eq(DataService:GetCandies(player), before, "partial change must be rolled back")
	end)

	H.test("unloaded players get nothing", function()
		local stranger = newPlayer()
		H.ok(not DataService:AddCandies(stranger, 100))
		H.eq(DataService:GetCandies(stranger), 0)
	end)

	-- Seed shop -------------------------------------------------------------------------
	local sessions = {}
	Registry.PlayerService = {
		GetSession = function(_, player)
			return sessions[player]
		end,
		Notify = noop,
	}

	local function fakeMatch(players)
		local match = {
			Id = 1,
			Wave = 1,
			ContinueLevel = 0,
			PhaseEndsAt = 0,
			Rng = H.Random.new(11),
			Sessions = {},
			Arena = { DoorCFrame = CFrame.new(0, 0, 0) },
		}
		function match:GetContext()
			return { Wave = self.Wave, ContinueLevel = self.ContinueLevel, PlayerCount = #players }
		end
		function match:GetPlayers()
			return players
		end
		function match:GetSessions()
			local list = {}
			for _, session in self.Sessions do
				table.insert(list, session)
			end
			return list
		end
		match.FireAll = noop
		match.Notify = noop
		match.SetAttribute = noop
		for _, player in players do
			local session = {
				Player = player,
				UserId = player.UserId,
				LifeState = "InMatch",
				Match = match,
				Position = Vector3.new(0, 0, 0),
			}
			function session:IsAlive()
				return true
			end
			function session:GetPosition()
				return self.Position
			end
			sessions[player] = session
			match.Sessions[player] = session
		end
		return match
	end

	local SeedShopService = H.Module("Server.Services.SeedShopService")
	Registry.SeedShopService = SeedShopService

	H.test("seed purchase charges once, grants the seed and decrements stock", function()
		local player = loadedPlayer()
		local match = fakeMatch({ player })
		SeedShopService:InitMatch(match)
		SeedShopService:Restock(match)
		SeedShopService:SetOpen(match, true)
		local shop = SeedShopService:GetSnapshot(match, player)
		local entry = shop.Entries[1]
		local candies = DataService:GetCandies(player)
		local seeds = DataService:GetSeedCount(player, entry.SeedId)

		local result = SeedShopService:Purchase(player, entry.SeedId, shop.Version)
		H.ok(result.Ok, result.Code)
		H.eq(DataService:GetCandies(player), candies - entry.Price)
		H.eq(DataService:GetSeedCount(player, entry.SeedId), seeds + 1)
		H.eq(SeedShopService:GetSnapshot(match, player).Entries[1].Quantity, entry.Quantity - 1)
	end)

	H.test("stale stock version is rejected without charging", function()
		local player = loadedPlayer()
		local match = fakeMatch({ player })
		SeedShopService:InitMatch(match)
		SeedShopService:Restock(match)
		SeedShopService:SetOpen(match, true)
		local shop = SeedShopService:GetSnapshot(match, player)
		SeedShopService:Restock(match)
		local candies = DataService:GetCandies(player)
		local result = SeedShopService:Purchase(player, shop.Entries[1].SeedId, shop.Version)
		H.eq(result.Code, ResultCode.StockChanged)
		H.eq(DataService:GetCandies(player), candies)
	end)

	H.test("closed shop and insufficient funds never touch stock", function()
		local player = loadedPlayer()
		local match = fakeMatch({ player })
		SeedShopService:InitMatch(match)
		SeedShopService:Restock(match)
		local shop = SeedShopService:GetSnapshot(match, player)
		local entry = shop.Entries[1]
		H.eq(SeedShopService:Purchase(player, entry.SeedId, shop.Version).Code, ResultCode.InvalidState)
		SeedShopService:SetOpen(match, true)
		DataService:Update(player, function(data) data.Candies = 0 end)
		H.eq(SeedShopService:Purchase(player, entry.SeedId, shop.Version).Code, ResultCode.InsufficientFunds)
		H.eq(SeedShopService:GetSnapshot(match, player).Entries[1].Quantity, entry.Quantity)
	end)

	H.test("two players racing for the last seed: exactly one wins", function()
		local a, b = loadedPlayer(), loadedPlayer()
		DataService:AddCandies(a, 10_000)
		DataService:AddCandies(b, 10_000)
		local match = fakeMatch({ a, b })
		SeedShopService:InitMatch(match)
		SeedShopService:Restock(match)
		SeedShopService:SetOpen(match, true)
		local shop = SeedShopService:GetSnapshot(match, a)
		local entry = shop.Entries[1]
		-- Drain to one remaining.
		for _ = 1, entry.Quantity - 1 do
			assert(SeedShopService:Purchase(a, entry.SeedId, shop.Version).Ok)
		end
		local results = {}
		local done = 0
		for _, player in { a, b } do
			task.spawn(function()
				table.insert(results, SeedShopService:Purchase(player, entry.SeedId, shop.Version))
				done += 1
			end)
		end
		while done < 2 do
			task.wait()
		end
		local wins = 0
		for _, result in results do
			if result.Ok then
				wins += 1
			else
				H.eq(result.Code, ResultCode.OutOfStock)
			end
		end
		H.eq(wins, 1)
		H.eq(SeedShopService:GetSnapshot(match, a).Entries[1].Quantity, 0)
	end)

	-- Class and upgrade purchases ------------------------------------------------------------
	local ClassService = H.Module("Server.Services.ClassService")
	local UpgradeService = H.Module("Server.Services.UpgradeService")

	H.test("class purchase is atomic and idempotent", function()
		local player = loadedPlayer()
		local price = ClassConfig.Get("Witch").Price
		H.eq(ClassService:PurchaseClass(player, "Witch").Code, ResultCode.InsufficientFunds)
		DataService:AddCandies(player, price)
		local before = DataService:GetCandies(player)
		H.ok(ClassService:PurchaseClass(player, "Witch").Ok)
		H.eq(ClassService:PurchaseClass(player, "Witch").Code, ResultCode.AlreadyOwned)
		H.eq(DataService:GetCandies(player), before - price, "charged exactly once")
		H.ok(DataService:OwnsCostume(player, "Witch"))
		H.eq(ClassService:PurchaseClass(player, "NoSuchClass").Code, ResultCode.NotFound)
	end)

	H.test("upgrades level up to the cap and stop charging", function()
		local player = loadedPlayer()
		local definition = EconomyConfig.PermanentUpgrades.GreenThumb
		local total = 0
		for _, cost in definition.Costs do
			total += cost
		end
		DataService:AddCandies(player, total)
		for level = 1, #definition.Costs do
			local result = UpgradeService:Purchase(player, "GreenThumb")
			H.ok(result.Ok, result.Code)
			H.eq(UpgradeService:GetLevel(player, "GreenThumb"), level)
		end
		local candies = DataService:GetCandies(player)
		H.eq(UpgradeService:Purchase(player, "GreenThumb").Code, ResultCode.MaxLevel)
		H.eq(DataService:GetCandies(player), candies)
		H.near(UpgradeService:GetGrowthSpeedMultiplier(player), 1 + #definition.Costs * definition.GrowthSpeedPerLevel, 1e-9)
	end)

	-- Extraction ---------------------------------------------------------------------------------
	local EscapeService = H.Module("Server.Services.EscapeService")
	local EscapeDoor = H.Module("Server.Classes.EscapeDoor")
	local grants, removed = {}, {}
	Registry.DifficultyService = H.Module("Server.Services.DifficultyService")
	Registry.HarvestChestService = {
		ComputePayout = function()
			return 500
		end,
	}
	Registry.CurrencyService = {
		Grant = function(_, player, currencyId, amount)
			table.insert(grants, { Player = player, Currency = currencyId, Amount = amount })
			return true
		end,
	}
	Registry.MatchService = {
		RemoveSession = function(_, session, reason)
			table.insert(removed, { Session = session, Reason = reason })
			-- Mirrors the real detach (Match:DetachSession + PlayerSession:ResetMatchState).
			session.Match.Sessions[session.Player] = nil
			session.Match = nil
		end,
	}
	-- The physical door needs the engine; the decision logic does not.
	EscapeDoor.new = function(_, cframe)
		return {
			GetPosition = function()
				return cframe.Position
			end,
			SetPromptText = noop,
			Destroy = noop,
		}
	end

	local function extractionMatch(count)
		table.clear(grants)
		table.clear(removed)
		local players = {}
		for _ = 1, count do
			table.insert(players, loadedPlayer())
		end
		local match = fakeMatch(players)
		EscapeService:InitMatch(match)
		EscapeService:OpenDoor(match)
		return match, players
	end

	local function grantsFor(player)
		local total = 0
		for _, grant in grants do
			if grant.Player == player then
				total += grant.Amount
			end
		end
		return total
	end

	H.test("escape pays exactly once and returns the player", function()
		local _, players = extractionMatch(2)
		local player = players[1]
		H.ok(EscapeService:SubmitDecision(player, "Escape").Ok)
		H.eq(EscapeService:SubmitDecision(player, "Escape").Code, ResultCode.NotInMatch, "already removed from the match")
		H.eq(grantsFor(player), 500)
		H.eq(#removed, 1)
		H.eq(removed[1].Reason, "Escaped")
	end)

	H.test("repeat decisions are rejected while still in the match", function()
		local _, players = extractionMatch(2)
		H.ok(EscapeService:SubmitDecision(players[1], "Continue").Ok)
		H.eq(EscapeService:SubmitDecision(players[1], "Escape").Code, ResultCode.AlreadyDone)
		H.eq(grantsFor(players[1]), 0)
	end)

	H.test("door range, closed door and dead players are enforced", function()
		local match, players = extractionMatch(2)
		sessions[players[1]].Position = Vector3.new(500, 0, 0)
		H.eq(EscapeService:SubmitDecision(players[1], "Escape").Code, ResultCode.OutOfRange)
		sessions[players[2]].LifeState = "Downed"
		H.eq(EscapeService:SubmitDecision(players[2], "Escape").Code, ResultCode.Dead)
		EscapeService:CloseDoor(match)
		sessions[players[1]].Position = Vector3.zero
		H.eq(EscapeService:SubmitDecision(players[1], "Escape").Code, ResultCode.InvalidState)
		H.eq(#grants, 0)
	end)

	H.test("anyone continuing keeps undecided players in the match", function()
		local match, players = extractionMatch(3)
		H.ok(EscapeService:SubmitDecision(players[1], "Continue").Ok)
		H.ok(EscapeService:SubmitDecision(players[2], "Escape").Ok)
		H.eq(EscapeService:Update(match, false), nil, "still waiting on player 3")
		H.eq(EscapeService:Update(match, true), "Continue")
		H.eq(grantsFor(players[3]), 0, "undecided player continues, not paid")
		H.eq(grantsFor(players[2]), 500)
	end)

	H.test("when nobody continues, undecided players are escaped and paid at the deadline", function()
		local match, players = extractionMatch(2)
		H.eq(EscapeService:Update(match, true), "End")
		H.eq(grantsFor(players[1]), 500)
		H.eq(grantsFor(players[2]), 500)
		H.eq(EscapeService:Update(match, true), "End", "empty match stays ended")
		H.eq(#grants, 2, "no second payout")
	end)
end
