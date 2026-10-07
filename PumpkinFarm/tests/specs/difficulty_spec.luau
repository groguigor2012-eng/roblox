return function(H)
	local Difficulty = H.Module("Server.Services.DifficultyService")
	local DifficultyConfig = H.Module("Shared.Config.DifficultyConfig")
	local EnemyConfig = H.Module("Shared.Config.EnemyConfig")

	local solo = function(wave, level)
		return { Wave = wave, ContinueLevel = level or 0, PlayerCount = 1 }
	end

	H.test("health grows ~1.2x per wave before the soft cap", function()
		for wave = 1, 14 do
			local ratio = Difficulty:GetWaveMultiplier("Health", wave + 1) / Difficulty:GetWaveMultiplier("Health", wave)
			H.near(ratio, 1.2, 1e-9, `wave {wave}`)
		end
	end)

	H.test("health growth slows after the soft cap and is hard capped", function()
		local curve = DifficultyConfig.Curves.Health
		local after = Difficulty:GetWaveMultiplier("Health", curve.SoftCapWave + 1) / Difficulty:GetWaveMultiplier("Health", curve.SoftCapWave)
		H.near(after, curve.PostSoftCapGrowth, 1e-9)
		H.eq(Difficulty:GetWaveMultiplier("Health", 500), curve.MaxMultiplier)
	end)

	H.test("speed scaling is damped and capped", function()
		H.eq(Difficulty:GetWaveMultiplier("Speed", 1), 1)
		local w10 = Difficulty:GetWaveMultiplier("Speed", 10)
		H.ok(w10 > 1.2 and w10 < 1.4, `wave 10 speed multiplier {w10}`)
		H.eq(Difficulty:GetWaveMultiplier("Speed", 200), DifficultyConfig.Curves.Speed.MaxMultiplier)
	end)

	H.test("all curves are monotonic", function()
		for name in DifficultyConfig.Curves do
			local previous = 0
			for wave = 1, 120 do
				local value = Difficulty:GetWaveMultiplier(name, wave)
				H.ok(value >= previous, `{name} decreased at wave {wave}`)
				previous = value
			end
		end
	end)

	H.test("continue factor weights the 1.5x multiplier per stat", function()
		H.near(Difficulty:GetContinueFactor("Health", 1), 1.5, 1e-9)
		H.near(Difficulty:GetContinueFactor("Health", 2), 2.25, 1e-9)
		H.near(Difficulty:GetContinueFactor("Speed", 1), 1 + 0.5 * 0.3, 1e-9)
		H.eq(Difficulty:GetContinueFactor("Density", 0), 1)
		local maxLevel = DifficultyConfig.Continue.MaxLevel
		H.eq(Difficulty:GetContinueFactor("Health", maxLevel + 5), Difficulty:GetContinueFactor("Health", maxLevel), "level is clamped")
	end)

	H.test("enemy stats combine base, wave, players and continue", function()
		local base = EnemyConfig.Get("ZombieFarmer")
		local stats = Difficulty:GetEnemyStats("ZombieFarmer", solo(1))
		H.eq(stats.MaxHealth, base.BaseHealth)
		H.near(stats.Speed, base.BaseSpeed, 1e-9)
		local four = Difficulty:GetEnemyStats("ZombieFarmer", { Wave = 1, ContinueLevel = 0, PlayerCount = 4 })
		H.ok(four.MaxHealth > stats.MaxHealth, "more players, tougher enemies")
		local continued = Difficulty:GetEnemyStats("ZombieFarmer", solo(5, 1))
		local normal = Difficulty:GetEnemyStats("ZombieFarmer", solo(5, 0))
		H.near(continued.MaxHealth / normal.MaxHealth, 1.5, 0.02)
		H.ok(continued.Speed < normal.Speed * 1.5, "continue must not multiply speed by the full 1.5")
	end)

	H.test("per-enemy scaling modifier dampens growth", function()
		local wave = 12
		local grunt = Difficulty:GetEnemyStats("ZombieFarmer", solo(wave))
		local boss = Difficulty:GetEnemyStats("CursedHarvester", solo(wave))
		local gruntGrowth = grunt.MaxHealth / EnemyConfig.Get("ZombieFarmer").BaseHealth
		local bossGrowth = boss.MaxHealth / EnemyConfig.Get("CursedHarvester").BaseHealth
		H.ok(bossGrowth < gruntGrowth, "boss Scaling.Health 0.6 grows slower than grunts")
	end)

	H.test("later bosses are stronger", function()
		local first = Difficulty:GetEnemyStats("CursedHarvester", solo(10))
		local second = Difficulty:GetEnemyStats("CursedHarvester", solo(20))
		H.ok(second.MaxHealth > first.MaxHealth)
		H.ok(Difficulty:IsBossWave(10) and Difficulty:IsBossWave(20) and not Difficulty:IsBossWave(15))
	end)

	H.test("enemy count and pacing", function()
		H.ok(Difficulty:GetEnemyCount(2, solo(2)) > Difficulty:GetEnemyCount(1, solo(1)))
		H.ok(Difficulty:GetEnemyCount(500, solo(500)) <= 140, "count is capped")
		H.ok(Difficulty:GetSpawnInterval(200, 5) >= 0.35, "interval never below minimum")
		H.ok(Difficulty:GetSpawnInterval(1, 2) < Difficulty:GetSpawnInterval(1, 0), "continue raises spawn pressure")
		H.ok(Difficulty:GetBurstSize(1) == 1 and Difficulty:GetBurstSize(100) <= 4)
	end)
end
