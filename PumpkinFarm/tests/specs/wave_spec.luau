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
end
