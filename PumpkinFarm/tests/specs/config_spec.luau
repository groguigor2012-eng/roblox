return function(H)
	local fs = require("@lune/fs")
	local CropConfig = H.Module("Shared.Config.CropConfig")
	local SeedConfig = H.Module("Shared.Config.SeedConfig")
	local EnemyConfig = H.Module("Shared.Config.EnemyConfig")
	local WaveConfig = H.Module("Shared.Config.WaveConfig")
	local ClassConfig = H.Module("Shared.Config.ClassConfig")
	local WeaponConfig = H.Module("Shared.Config.WeaponConfig")
	local StatusEffectConfig = H.Module("Shared.Config.StatusEffectConfig")
	local DefenseConfig = H.Module("Shared.Config.DefenseConfig")
	local EconomyConfig = H.Module("Shared.Config.EconomyConfig")
	local NetworkConfig = H.Module("Shared.Config.NetworkConfig")
	local Rarity = H.Module("Shared.Data.Rarity")

	H.test("every crop is complete and every seed maps to a crop", function()
		for id, crop in CropConfig.Crops do
			H.eq(crop.Id, id)
			H.ok(Rarity[crop.Rarity], `{id} rarity`)
			H.ok(crop.SeedPrice > 0 and crop.GrowthDuration > 0 and crop.YieldQuantity > 0 and crop.MaxHealth > 0, id)
			H.eq(crop.Stages[#crop.Stages].AtProgress, 1, `{id} final stage must be ripe`)
			H.ok(crop.Vulnerability.Ground and crop.Vulnerability.Air and crop.Vulnerability.Underground and crop.Vulnerability.Boss, id)
		end
		for seedId, rule in SeedConfig.Seeds do
			H.ok(CropConfig.Get(seedId), `seed {seedId} has no crop`)
			H.ok(rule.Quantity[1] <= rule.Quantity[2] and rule.PriceVariance[1] <= rule.PriceVariance[2], seedId)
		end
		for _, required in { "NeonStarFruit", "GhostPepper", "VoidPumpkin" } do
			H.ok(CropConfig.Get(required), `required crop {required}`)
		end
	end)

	H.test("every crop pays back its seed when harvested", function()
		for id, crop in CropConfig.Crops do
			H.ok(crop.YieldQuantity * crop.UnitValue > crop.SeedPrice * 1.25, `{id} is not profitable`)
		end
	end)

	H.test("every enemy has an AI class module and sane stats", function()
		for id, enemy in EnemyConfig.Enemies do
			H.eq(enemy.Id, id)
			H.ok(fs.isFile(`src/server/AI/{enemy.Class}.luau`), `{id} AI class {enemy.Class} missing`)
			H.ok(enemy.BaseHealth > 0 and enemy.BaseSpeed > 0 and enemy.UpdateInterval > 0, id)
			H.ok(enemy.Scaling and enemy.Scaling.Health and enemy.Scaling.Speed, id)
		end
		for id in WaveConfig.Archetypes do
			H.ok(EnemyConfig.Get(id), `wave archetype {id}`)
		end
		H.ok(EnemyConfig.Get(WaveConfig.BossEnemyId).IsBoss)
		H.ok(EnemyConfig.Get(EnemyConfig.Get("Witch").MinionId), "witch minion exists")
		H.ok(StatusEffectConfig.Get(EnemyConfig.Get("Witch").PotionEffect), "witch potion effect exists")
	end)

	H.test("every class references a weapon module and an ability", function()
		H.ok(ClassConfig.Get(ClassConfig.DefaultClassId).DefaultUnlocked)
		for id, class in ClassConfig.Classes do
			local weapon = WeaponConfig.Weapons[class.WeaponId]
			H.ok(weapon, `{id} weapon`)
			H.ok(fs.isFile(`src/server/Classes/Weapons/{weapon.Module}.luau`), `{id} weapon module`)
			H.ok(WeaponConfig.Abilities[class.AbilityId], `{id} ability`)
		end
		H.eq(WeaponConfig.Weapons.MagicStaff.Damage, 35)
		H.eq(WeaponConfig.Weapons.MagicStaff.AOERadius, 12)
		H.eq(WeaponConfig.Weapons.MagicStaff.Cooldown, 1.2)
		H.eq(WeaponConfig.Weapons.ReaperScythe.Damage, 75)
		H.eq(WeaponConfig.Weapons.ReaperScythe.CleaveRadius, 10)
		H.eq(WeaponConfig.Weapons.ReaperScythe.Cooldown, 1.5)
		H.ok(StatusEffectConfig.Get(WeaponConfig.Abilities.HexNova.Effect))
	end)

	H.test("stun is non-stacking with an immunity window", function()
		local stun = StatusEffectConfig.Get("Stunned")
		H.eq(stun.Duration, 2)
		H.eq(stun.Stacking, "Ignore")
		H.ok((stun.ImmunityDuration or 0) > 0)
	end)

	H.test("defenses, items and upgrades are consistent", function()
		for id, defense in DefenseConfig.Defenses do
			H.eq(defense.Id, id)
			H.ok(defense.Kind == "Barricade" or defense.Kind == "Sentry", id)
			for _, upgrade in defense.Upgrades or {} do
				H.ok(upgrade.Cost > 0, id)
			end
			if defense.Effect then
				H.ok(StatusEffectConfig.Get(defense.Effect), `{id} effect`)
			end
		end
		for id, item in DefenseConfig.Items do
			H.eq(item.Id, id)
			H.ok(item.Kind == "Accessory" or item.Kind == "Utility", id)
		end
		for id, upgrade in EconomyConfig.PermanentUpgrades do
			H.eq(upgrade.Id, id)
		end
		H.ok(CropConfig.Get(EconomyConfig.SoftLockGrant.SeedId))
	end)

	H.test("every client->server remote is rate limited and has a schema", function()
		for name, remote in NetworkConfig.Remotes do
			if remote.Direction == "ClientToServer" then
				H.ok(remote.RateLimit, `{name} rate limit`)
				H.ok(remote.Args, `{name} schema`)
			else
				H.eq(remote.Class, "RemoteEvent", `{name}: server->client must be an event (never invoke the client)`)
			end
		end
	end)
end
