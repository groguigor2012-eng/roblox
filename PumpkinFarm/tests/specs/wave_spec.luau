return function(H)
	local WaveComposer = H.Module("Server.Systems.WaveComposer")
	local Difficulty = H.Module("Server.Services.DifficultyService")
	local WaveConfig = H.Module("Shared.Config.WaveConfig")

	local function compose(wave, level, seed, players)
		return WaveComposer.Compose(wave, { Wave = wave, ContinueLevel = level or 0, PlayerCount = players or 1 }, H.Random.new(seed or 7), Difficulty)
	end

	H.test("wave 1 is only grunts", function()
		local plan = compose(1)
		for _, id in plan.Entries do
			H.eq(id, WaveConfig.GruntEnemyId)
		end
		H.eq(#plan.Entries, Difficulty:GetEnemyCount(1, { Wave = 1, ContinueLevel = 0, PlayerCount = 1 }))
	end)

	H.test("plans are deterministic for the same seed", function()
		local a, b = compose(9, 1, 123), compose(9, 1, 123)
		H.eq(table.concat(a.Entries, ","), table.concat(b.Entries, ","))
	end)

	H.test("archetypes respect unlock waves and caps", function()
		for wave = 1, 40 do
			local plan = compose(wave, 0, wave)
			local total = #plan.Entries
			for enemyId, rule in WaveConfig.Archetypes do
				local count = plan.Counts[enemyId] or 0
				if wave < rule.UnlockWave then
					H.eq(count, 0, `{enemyId} before unlock at wave {wave}`)
				end
				H.ok(count <= math.max(1, math.floor(total * rule.MaxShare)), `{enemyId} over share at wave {wave}`)
				if rule.MaxPerWave then
					H.ok(count <= rule.MaxPerWave, `{enemyId} over MaxPerWave`)
				end
			end
		end
	end)

	H.test("boss waves start with the Cursed Harvester", function()
		local plan = compose(10)
		H.ok(plan.IsBoss)
		H.eq(plan.Entries[1], WaveConfig.BossEnemyId)
		H.ok(not compose(11).IsBoss)
	end)

	H.test("backline witches never lead the wave", function()
		for seed = 1, 30 do
			local plan = compose(14, 2, seed)
			local lead = math.max(1, math.floor((#plan.Entries - (plan.Counts.Witch or 0)) * WaveConfig.FrontlineLead))
			for index, id in plan.Entries do
				if id == "Witch" then
					H.ok(index > lead, `witch at position {index} (lead {lead})`)
				end
			end
		end
	end)

	H.test("continue mode increases specialised pressure", function()
		local function specials(level)
			local total = 0
			for seed = 1, 20 do
				local plan = compose(12, level, seed)
				total += #plan.Entries - (plan.Counts[WaveConfig.GruntEnemyId] or 0)
			end
			return total
		end
		H.ok(specials(3) > specials(0), "continue level 3 must field more specialists")
	end)

	H.test("threat budget: plans never overspend, at any wave, Continue level or party size", function()
		for _, players in { 1, 4 } do
			for level = 0, 3 do
				for wave = 1, 60 do
					local plan = compose(wave, level, wave * 31 + level, players)
					H.ok(plan.Threat <= plan.Budget + 1e-6, `wave {wave} L{level} P{players}: threat {plan.Threat} > budget {plan.Budget}`)
					local recount = 0
					for enemyId, count in plan.Counts do
						if enemyId ~= WaveConfig.BossEnemyId then
							local rule = WaveConfig.Archetypes[enemyId]
							recount += count * (if rule then rule.Cost else WaveConfig.GruntCost)
						end
					end
					H.ok(math.abs(recount - plan.Threat) < 1e-6, "threat is the sum of costs")
				end
			end
		end
	end)

	H.test("the budget binds: expensive specialists are limited by it, not only by share", function()
		local unlimited = 0
		local limited = 0
		for seed = 1, 30 do
			local plan = compose(8, 0, seed)
			limited += plan.Counts.Witch or 0
			unlimited += math.min(WaveConfig.Archetypes.Witch.MaxPerWave, math.floor(#plan.Entries * WaveConfig.Archetypes.Witch.MaxShare))
		end
		H.ok(limited <= unlimited)
		local early = compose(3, 0, 5)
		H.ok(early.Budget < compose(20, 0, 5).Budget, "budget grows with the wave")
		H.ok(compose(12, 2, 5).Budget > compose(12, 0, 5).Budget, "Continue raises the budget")
	end)

	H.test("composition evolves: grunts early, moles and scarecrows mid, crows and witches later", function()
		local function seen(fromWave, toWave)
			local kinds = {}
			for wave = fromWave, toWave do
				for seed = 1, 6 do
					for enemyId, count in compose(wave, 0, seed * 97 + wave).Counts do
						if count > 0 then
							kinds[enemyId] = true
						end
					end
				end
			end
			return kinds
		end
		local early, mid, late = seen(1, 2), seen(3, 7), seen(8, 19)
		H.ok(early.ZombieFarmer and not early.ZombieMole and not early.PlagueCrow and not early.Witch, "early: farmers only")
		H.ok(mid.ZombieMole and mid.BlightedScarecrow and mid.ZombieFarmer and not mid.Witch, "mid: farmers, moles, scarecrows")
		H.ok(late.PlagueCrow and late.Witch and late.ZombieMole and late.BlightedScarecrow, "late: crows, witches, mixed")
		H.ok(compose(10, 0, 1).Entries[1] == WaveConfig.BossEnemyId and compose(20, 0, 1).IsBoss, "boss every 10 waves")
	end)
end
