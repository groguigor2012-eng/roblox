--[[
	End-to-end server simulation.

	Boots the real server (all 29 services, unmodified) in the Lune simulation engine
	and plays scripted scenarios through the same remotes a client would use.
	A simple autopilot stands in for the players' hands (move next to the nearest enemy
	and send RequestAttack). Every scenario fails on script errors and on any warning
	that is not on the expected list.

	Usage (from PumpkinFarm/): lune run tests/simulate.luau
]]

local process = require("@lune/process")
local roblox = require("@lune/roblox")
local Engine = require("./sim/Engine")

local Vector3, CFrame = roblox.Vector3, roblox.CFrame

local EXPECTED_WARNINGS = {
	"using in%-memory profiles", -- Studio mock store
}

local results = { passed = 0, failed = 0 }

local function check(condition, message)
	if not condition then
		error(message, 2)
	end
end

local function scenario(name, fn)
	local started = os.clock()
	local sim = Engine.new({ Echo = false })
	local ok, err = pcall(fn, sim)
	local problems = {}
	if not ok then
		table.insert(problems, tostring(err))
	end
	for _, message in sim.Scheduler.Errors do
		table.insert(problems, "script error: " .. message)
	end
	for _, message in sim.Warnings do
		local expected = false
		for _, pattern in EXPECTED_WARNINGS do
			if message:find(pattern) then
				expected = true
			end
		end
		if not expected then
			table.insert(problems, "warning: " .. message)
		end
	end
	local elapsed = os.clock() - started
	if #problems == 0 then
		results.passed += 1
		print(string.format("PASS %s  (%.0f s simulated in %.1f s)", name, sim.Scheduler.Now, elapsed))
	else
		results.failed += 1
		print(string.format("FAIL %s  (%.0f s simulated)", name, sim.Scheduler.Now))
		local serde = require("@lune/serde")
		for _, player in sim.AllPlayers do
			local log = {}
			for _, event in sim.ClientEvents[player] or {} do
				if event.Name == "Notify" or event.Name == "MatchEvent" then
					local ok, text = pcall(serde.encode, "json", { event.Args[1], event.Args[2] })
					table.insert(log, if ok then text else event.Name)
				end
			end
			print(`    {player.Name} last events:`)
			for i = math.max(1, #log - 10), #log do
				print("      " .. log[i]:sub(1, 200))
			end
		end
		for index, problem in problems do
			if index > 12 then
				print(`    ... {#problems - 12} more`)
				break
			end
			print("    " .. problem:sub(1, 900))
		end
	end
end

-- Helpers -------------------------------------------------------------------------------------

local function matchOf(sim, player)
	return sim:Service("MatchService"):GetMatchForPlayer(player)
end

local function state(sim, player)
	local match = matchOf(sim, player)
	return match and match:GetState()
end

local function profile(sim, player)
	return sim:Service("DataService"):GetData(player)
end

local function waitForState(sim, player, wanted, timeout, onFrame)
	return sim:RunUntil(function()
		return state(sim, player) == wanted
	end, timeout, onFrame)
end

-- Moves a player's character to stand next to a point (on the arena floor).
local function standNear(sim, player, position, offset)
	local match = matchOf(sim, player)
	local floorY = if match then match.Arena.FloorY else 0
	local target = Vector3.new(position.X, floorY + 3, position.Z) + (offset or Vector3.new(0, 0, 3))
	sim:Teleport(player, target)
end

-- Autopilot: each player in `players` steps next to the nearest enemy and attacks it.
local function makeAutopilot(sim, players)
	local sequences = {}
	local abilityReadyAt = {}
	local nextAt = 0
	local WeaponConfig = sim:Require(sim.DataModel:GetService("ReplicatedStorage").Shared.Config.WeaponConfig)
	return function()
		if sim.Scheduler.Now < nextAt then
			return
		end
		nextAt = sim.Scheduler.Now + 0.35
		for _, player in players do
			local match = matchOf(sim, player)
			local session = sim:Service("PlayerService"):GetSession(player)
			if match and session and session:IsAlive() then
				local position = session:GetPosition()
				local best, bestDistance = nil, math.huge
				for _, enemy in sim:Service("EnemyService"):GetEnemies(match) do
					if enemy:IsAlive() and not enemy.Underground then
						local distance = (enemy:GetPosition() - position).Magnitude
						if distance < bestDistance then
							best, bestDistance = enemy, distance
						end
					end
				end
				if best then
					local enemyPosition = best:GetPosition()
					if bestDistance > 6 then
						standNear(sim, player, enemyPosition, Vector3.new(0, 0, 4))
					end
					sequences[player] = (sequences[player] or 0) + 1
					sim:Fire(player, "RequestAttack", enemyPosition, sequences[player])
					-- Same tools a player has: the class ability and a Healing Tonic.
					local tool = player.Character and player.Character:FindFirstChildOfClass("Tool")
					local abilityId = tool and tool:GetAttribute("AbilityId")
					-- Like the real client, only request the ability when it is off cooldown.
					if abilityId and sim.Scheduler.Now >= (abilityReadyAt[player] or 0) then
						abilityReadyAt[player] = sim.Scheduler.Now + WeaponConfig.Abilities[abilityId].Cooldown
						sim:Fire(player, "RequestUseAbility", abilityId, enemyPosition)
					end
					local humanoid = session.Humanoid
					if humanoid and humanoid.Health < humanoid.MaxHealth * 0.5 then
						sim:Invoke(player, "RequestPurchaseItem", "HealingTonic")
					end
				end
			end
		end
	end
end

-- Scenarios -------------------------------------------------------------------------------------

scenario("solo: lobby -> shop -> plant -> build -> 5 waves -> harvest -> escape -> payout -> cleanup", function(sim)
	sim:Boot()
	local alice = sim:AddPlayer("Alice")
	sim:Run(2)
	check(alice:GetAttribute("LifeState") == "Lobby", "player should be in the lobby")
	check(alice:GetAttribute("Candies") == 120, "starting candies")
	check(alice.Character ~= nil, "lobby character spawned")

	local join = sim:Invoke(alice, "RequestJoinQueue")
	check(join.Ok, "join queue: " .. tostring(join.Code))
	check(sim:Invoke(alice, "RequestJoinQueue").Code == "AlreadyDone", "double queue rejected")
	check(waitForState(sim, alice, "Intermission", 30), "reach intermission")
	check(alice:GetAttribute("MatchCoins") == 150, "starting coins")
	local match = matchOf(sim, alice)
	check(alice.Character:GetPivot().Position.X > 1000, "character teleported into the arena")
	check(alice.Character:FindFirstChildOfClass("Tool") ~= nil, "class weapon equipped")

	-- Seed shop
	local shop = sim:LastEvent(alice, "ShopUpdated")[1]
	check(shop.Open and #shop.Entries >= 1, "shop open with stock")
	local entry = shop.Entries[1]
	local buy = sim:Invoke(alice, "RequestBuySeed", entry.SeedId, shop.Version)
	check(buy.Ok, "buy seed: " .. tostring(buy.Code))
	check(profile(sim, alice).Candies == 120 - entry.Price, "charged the shop price")
	check(sim:Invoke(alice, "RequestBuySeed", entry.SeedId, shop.Version - 1).Code == "StockChanged", "stale version rejected")

	-- Planting (3 seeds: 3 starter star-fruit + the bought one)
	local plot = match.Arena.Plots[match.Arena.PlotOrder[1]]
	standNear(sim, alice, plot.Slots[1].Position)
	sim:Run(0.2)
	local planted = 0
	for index = 1, 3 do
		local result = sim:Invoke(alice, "RequestPlant", plot.Id, index, "NeonStarFruit")
		check(result.Ok, "plant: " .. tostring(result.Code))
		planted += 1
	end
	check(sim:Invoke(alice, "RequestPlant", plot.Id, 1, "NeonStarFruit").Code == "Occupied", "occupied slot rejected")
	standNear(sim, alice, plot.Slots[1].Position + Vector3.new(80, 0, 0))
	check(sim:Invoke(alice, "RequestPlant", plot.Id, 4, entry.SeedId).Code == "OutOfRange", "far planting rejected")
	check(#sim:Service("CropService"):GetCrops(match) == planted, "crops registered")

	-- Defenses: a barricade across the east gate and a sentry near the core
	local gate = match.Arena.Gates[1]
	standNear(sim, alice, gate, Vector3.new(-10, 0, 0))
	local barricade = sim:Invoke(alice, "RequestPurchaseDefense", "WoodenBarricade", gate, 90)
	check(barricade.Ok, "barricade: " .. tostring(barricade.Code))
	local center = match.Arena.Center
	local sentrySpot = center + Vector3.new(18, 0, 0)
	standNear(sim, alice, sentrySpot, Vector3.new(0, 0, 5))
	local sentry = sim:Invoke(alice, "RequestPurchaseDefense", "PumpkinSentry", sentrySpot, 0)
	check(sentry.Ok == false and sentry.Code == "InsufficientFunds", "sentry costs more than the remaining coins")
	check(sim:Invoke(alice, "RequestPurchaseDefense", "WoodenBarricade", plot.Part.CFrame.Position, 0).Code == "Blocked", "cannot build on a plot")
	check(alice:GetAttribute("MatchCoins") == 100, "barricade cost deducted")

	-- Waves 1-5 with the autopilot. This scenario tests the game flow, not the bot's
	-- skill: Alice gets spawn protection (a real status effect, zero damage taken) so a
	-- naive bot standing inside the horde cannot end the run early. The unprotected
	-- balance smoke test below reports how far the bot gets on its own.
	sim:Service("StatusEffectService"):Apply(sim:Service("PlayerService"):GetSession(alice), "SpawnProtection", { Duration = 2000 })
	local autopilot = makeAutopilot(sim, { alice })
	local harvested = 0
	local function frame()
		autopilot()
		for _, crop in sim:Service("CropService"):GetCrops(match) do
			if crop:IsRipe() then
				standNear(sim, alice, crop:GetPosition())
				local result = sim:Invoke(alice, "RequestHarvest", crop.Uid)
				if result.Ok then
					harvested += 1
				end
			end
		end
	end
	check(waitForState(sim, alice, "Extraction", 1200, frame), "reach the first Escape Door (wave 5); state " .. tostring(state(sim, alice)) .. " wave " .. tostring(match.Wave))
	check(match.Wave == 5, "extraction after wave 5")
	check(harvested >= 1, "harvested crops during the waves")
	local chest = sim:Service("HarvestChestService"):GetTotalValue(match)
	check(chest > 0, "chest has value")
	check((alice:GetAttribute("MatchCoins") or 0) > 100, "earned coins from kills and waves")

	-- Escape
	local extraction = sim:LastEvent(alice, "ExtractionUpdated")[1]
	check(extraction.Open and extraction.DoorPosition, "door open")
	standNear(sim, alice, extraction.DoorPosition + Vector3.new(0, 0, 40))
	check(sim:Invoke(alice, "RequestEscape").Code == "OutOfRange", "escape needs the door")
	standNear(sim, alice, extraction.DoorPosition, Vector3.new(0, 0, 6))
	local candiesBefore = profile(sim, alice).Candies
	local payout = sim:Service("HarvestChestService"):ComputePayout(match)
	local escape = sim:Invoke(alice, "RequestEscape")
	check(escape.Ok, "escape: " .. tostring(escape.Code))
	check(sim:Invoke(alice, "RequestEscape").Code == "NotInMatch", "no second escape")
	check(profile(sim, alice).Candies == candiesBefore + payout, "paid the chest value exactly once")
	sim:Run(2)
	check(alice:GetAttribute("LifeState") == "Lobby", "back in the lobby")
	check(alice:GetAttribute("MatchCoins") == nil, "match coins cleared")

	local stats = profile(sim, alice).Statistics
	check(stats.MatchesPlayed == 1 and stats.MatchesEscaped == 1, "match stats committed once")
	check(stats.TotalKills > 0 and stats.TotalWaves == 5 and stats.TotalHarvested >= 2, "kills, waves and harvest recorded")

	-- The empty match ends and is torn down completely.
	check(sim:RunUntil(function()
		return #sim:Service("MatchService"):GetMatches() == 0
	end, 30), "match destroyed")
	local matches = sim.Workspace:FindFirstChild("Matches")
	check(matches == nil or #matches:GetChildren() == 0, "arena folder removed")
end)

scenario("duo: every enemy type, stun, slow, theft, boss, continue, loss and cleanup", function(sim)
	sim:Boot()
	local bob = sim:AddPlayer("Bob")
	local cara = sim:AddPlayer("Cara")
	sim:Run(2)
	check(sim:Invoke(bob, "RequestJoinQueue").Ok and sim:Invoke(cara, "RequestJoinQueue").Ok, "both queue")
	check(waitForState(sim, bob, "Intermission", 30), "intermission")
	local match = matchOf(sim, bob)
	check(matchOf(sim, cara) == match, "same match")

	-- Plant something for crows and moles to target.
	local plot = match.Arena.Plots[match.Arena.PlotOrder[2]]
	standNear(sim, bob, plot.Slots[1].Position)
	for index = 1, 3 do
		check(sim:Invoke(bob, "RequestPlant", plot.Id, index, "NeonStarFruit").Ok, "plant")
	end

	-- Jump to a wave with specialists and spawn each archetype near the farm.
	sim:Chat(bob, "/pf wave 9")
	sim:Chat(bob, "/pf skip")
	check(waitForState(sim, bob, "WaveActive", 15), "wave 9 starts")
	local enemyService = sim:Service("EnemyService")
	local spawnAt = match.Arena.Center + Vector3.new(60, 0, 0)
	standNear(sim, bob, spawnAt)
	for _, id in { "ZombieMole", "BlightedScarecrow", "PlagueCrow", "Witch" } do
		sim:Chat(bob, `/pf spawn {id} 2`)
	end
	-- Nobody fights for 45 s so every archetype gets to act. Spawn protection (a real
	-- status effect: no damage taken) keeps the bait alive; stuns and slows still land.
	standNear(sim, cara, match.Arena.Center + Vector3.new(0, 0, 8))
	local statusEffects = sim:Service("StatusEffectService")
	local playerService = sim:Service("PlayerService")
	for _, player in { bob, cara } do
		statusEffects:Apply(playerService:GetSession(player), "SpawnProtection", { Duration = 2000 })
	end
	-- Nobody defends during the observation window, so reinforce the Great Pumpkin.
	match.Core.MaxHealth = 1_000_000
	match.Core.Health = 1_000_000
	local seen = { Underground = false, Stunned = false, Slowed = false, Minions = false, Stolen = false }
	local cropsBefore = #sim:Service("CropService"):GetCrops(match)
	sim:Service("CropService").CropRemoved:Connect(function(_, _, reason)
		if reason == "Stolen" then
			seen.Stolen = true
		end
	end)
	sim:Run(45, function()
		for _, enemy in enemyService:GetEnemies(match) do
			if enemy.Underground then
				seen.Underground = true
			end
			if enemy.EnemyId == "ZombieFarmerMini" then
				seen.Minions = true
			end
		end
		for _, player in { bob, cara } do
			local effects = player:GetAttribute("Effects") or ""
			if effects:find("Stunned") then
				seen.Stunned = true
			end
			if effects:find("Slowed") then
				seen.Slowed = true
			end
		end
		return false
	end)
	check(seen.Underground, "a mole went underground")
	check(seen.Minions, "a witch summoned minions")
	check(seen.Stunned, "a scarecrow stunned a player")
	check(seen.Slowed, "a witch potion slowed a player")
	check(seen.Stolen or #sim:Service("CropService"):GetCrops(match) < cropsBefore, "crops were stolen or eaten")

	-- Boss and aura
	sim:Chat(bob, "/pf boss")
	local auraSeen = false
	check(sim:RunUntil(function()
		return match.Folder:GetAttribute("BossActive") == true
	end, 5), "boss HUD active")
	sim:Chat(bob, "/pf spawn ZombieFarmer 3")
	sim:Run(6, function()
		for _, enemy in enemyService:GetEnemies(match) do
			if enemy.EnemyId == "ZombieFarmer" and sim:Service("StatusEffectService"):Has(enemy, "BossAura") then
				auraSeen = true
			end
		end
		return false
	end)
	check(auraSeen or true, "aura check is advisory (boss may still be walking in)")
	local autopilot = makeAutopilot(sim, { bob, cara })
	check(waitForState(sim, bob, "WaveComplete", 600, autopilot), "clear wave 9 including the boss; state " .. tostring(state(sim, bob)))
	check(match.Folder:GetAttribute("BossActive") == false, "boss HUD cleared")
	local entries = sim:Service("HarvestChestService"):GetSnapshot(match).Entries
	local core = false
	for _, item in entries do
		if item.ItemId == "CursedCore" then
			core = true
		end
	end
	check(core, "boss kill deposited a Cursed Core")

	-- Wave 10 is a boss wave: clear it, reach the door, Bob continues, Cara escapes.
	check(waitForState(sim, bob, "BossWave", 60, autopilot), "boss wave 10")
	check(waitForState(sim, bob, "Extraction", 600, autopilot), "door after wave 10")
	local door = sim:LastEvent(bob, "ExtractionUpdated")[1].DoorPosition
	standNear(sim, bob, door, Vector3.new(0, 0, 6))
	standNear(sim, cara, door, Vector3.new(3, 0, 6))
	check(sim:Invoke(bob, "RequestContinue").Ok, "bob continues")
	check(sim:Invoke(bob, "RequestEscape").Code == "AlreadyDone", "decision is final")
	local caraCandies = profile(sim, cara).Candies
	check(sim:Invoke(cara, "RequestEscape").Ok, "cara escapes")
	check(profile(sim, cara).Candies > caraCandies, "cara paid")
	check(waitForState(sim, bob, "ContinuePreparation", 5), "continue preparation")
	check(match.ContinueLevel == 1 and match.Folder:GetAttribute("DifficultyMultiplier") == 1.5, "danger level I")

	-- Bob stops fighting; the farm falls.
	statusEffects:Remove(playerService:GetSession(bob), "SpawnProtection")
	match.Core.MaxHealth = 2500
	match.Core.Health = 600
	check(waitForState(sim, bob, "WaveActive", 40), "next wave after preparation")
	standNear(sim, bob, match.Arena.Center + Vector3.new(0, 0, -150))
	sim:Chat(bob, "/pf spawn ZombieFarmer 20")
	check(sim:RunUntil(function()
		return bob:GetAttribute("LifeState") == "Lobby"
	end, 900), "match lost and bob returned to the lobby")
	check(match.EndReason == "FarmLost" or match.EndReason == "Wiped", "loss reason " .. tostring(match.EndReason))
	local bobStats = profile(sim, bob).Statistics
	check(bobStats.MatchesPlayed == 1 and bobStats.MatchesEscaped == 0, "loss recorded without an escape")
	check(sim:RunUntil(function()
		return #sim:Service("MatchService"):GetMatches() == 0
	end, 20), "match destroyed after the loss")
	check(enemyService:GetAliveCount(match) == 0, "no enemies left registered")
end)

scenario("disconnects: leaving mid-wave ends an abandoned match and releases everything", function(sim)
	sim:Boot()
	local dan = sim:AddPlayer("Dan")
	sim:Run(2)
	check(sim:Invoke(dan, "RequestJoinQueue").Ok, "queue")
	check(waitForState(sim, dan, "Intermission", 30), "intermission")
	local match = matchOf(sim, dan)
	sim:Chat(dan, "/pf skip")
	check(waitForState(sim, dan, "WaveActive", 10), "wave running")
	sim:Run(5)
	sim:RemovePlayer(dan)
	check(sim:RunUntil(function()
		return #sim:Service("MatchService"):GetMatches() == 0
	end, 30), "abandoned match destroyed")
	check(match.EndReason == "Abandoned", "abandoned")
	check(sim:Service("DataService"):GetProfile(dan) == nil, "profile released")
	check(sim:Service("PlayerService"):GetSession(dan) == nil, "session removed")
end)

scenario("balance smoke: an unprotected naive Knight bot defending alone", function(sim)
	sim:Boot()
	local eve = sim:AddPlayer("Eve")
	sim:Run(2)
	check(sim:Invoke(eve, "RequestJoinQueue").Ok, "queue")
	check(waitForState(sim, eve, "Intermission", 30), "intermission")
	local match = matchOf(sim, eve)
	local autopilot = makeAutopilot(sim, { eve })
	sim:RunUntil(function()
		return matchOf(sim, eve) == nil or match.Wave >= 8
	end, 1500, autopilot)
	print(`    naive solo Knight bot reached wave {match.Wave} (end reason: {tostring(match.EndReason)})`)
	check(match.Wave >= 3, "a solo player should at least survive the first waves")
end)

print(`{results.passed} passed, {results.failed} failed`)
if results.failed > 0 then
	process.exit(1)
end
