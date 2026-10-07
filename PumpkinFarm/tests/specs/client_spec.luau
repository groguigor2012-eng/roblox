-- Builds the entire client UI headlessly: every controller's Init in bootstrap order,
-- then the data-driven panels with sample state. Lune validates every GUI property
-- name and value type, so a typo in any UI builder fails here.
return function(H)
	local player = H.CreateLocalPlayer()
	local ORDER = {
		"NotificationController",
		"AudioController",
		"EffectsController",
		"HUDController",
		"WaveUIController",
		"LobbyController",
		"ClassController",
		"SeedShopController",
		"CropController",
		"HarvestChestController",
		"DefenseShopController",
		"EscapeController",
		"WeaponController",
		"BossBarController",
	}
	local Controllers = H.Module("Client.Modules.ControllerRegistry")
	local ClientState = H.Module("Client.Modules.ClientState")

	for _, name in ORDER do
		H.test(`client {name} Init`, function()
			local controller = H.Module(`Client.Controllers.{name}`)
			Controllers[name] = controller
			if controller.Init then
				controller:Init()
			end
		end)
	end

	H.test("every ScreenGui from the brief exists", function()
		for _, name in { "MainHUD", "ShopUI", "HarvestUI", "EscapeUI", "ClassUI", "BossUI", "LobbyUI", "UpgradeUI", "DefenseUI", "BannerUI", "CombatUI", "NotificationUI", "EffectsUI" } do
			local gui = player.PlayerGui:FindFirstChild(name)
			H.ok(gui and gui:IsA("ScreenGui"), `{name} missing`)
			H.eq(gui.ResetOnSpawn, false, `{name} must survive respawns`)
		end
	end)

	ClientState.Profile = {
		Candies = 1234,
		UnlockedCostumes = { Knight = true },
		EquippedCostume = "Knight",
		Seeds = { NeonStarFruit = 3, VoidPumpkin = 1 },
		PermanentUpgrades = { DeepPockets = 2 },
		Statistics = { TotalKills = 10, HighestWave = 7, MatchesPlayed = 2, MatchesEscaped = 1 },
		Settings = { MusicEnabled = true, EffectsEnabled = false },
		IsTemporary = true,
	}
	ClientState.Shop = {
		Version = 3,
		Open = true,
		RestockedAt = 0,
		Entries = {
			{ SeedId = "NeonStarFruit", Quantity = 5, Price = 30, Purchased = 0 },
			{ SeedId = "VoidPumpkin", Quantity = 0, Price = 240, PerPlayerLimit = 2, Purchased = 2 },
		},
	}
	ClientState.Chest = {
		Entries = { { ItemId = "VoidPumpkin", DisplayName = "Void Pumpkin", Icon = "🎃", Quantity = 2, UnitValue = 600, Value = 1200 } },
		TotalValue = 1200,
		EstimatedCandies = 1500,
		RiskBonus = 0.25,
		Locked = false,
	}

	H.test("data-driven panels render sample state", function()
		Controllers.ClassController:Refresh()
		Controllers.SeedShopController:Refresh()
		Controllers.SeedShopController:RefreshPouch()
		Controllers.SeedShopController:SelectSeed("NeonStarFruit")
		Controllers.HarvestChestController:Refresh()
		Controllers.DefenseShopController:Refresh()
		Controllers.WaveUIController:ShowBanner("WAVE 3", "test", nil, 0.01)
		Controllers.NotificationController:Notify("hello", "Info", 0.01)
		Controllers.NotificationController:ShowResult({ Ok = true, Code = "Ok" }, "done")
		local class = player.PlayerGui.ClassUI.ClassUI.List
		local cards = 0
		for _, child in class:GetChildren() do
			if child:IsA("Frame") then
				cards += 1
			end
		end
		H.eq(cards, 2, "one card per class")
		H.eq(Controllers.SeedShopController:GetSelectedSeed(), "NeonStarFruit")
	end)

	H.test("locked chest and empty states render", function()
		ClientState.Chest = { Entries = {}, TotalValue = 0, EstimatedCandies = 0, RiskBonus = 0, Locked = true }
		Controllers.HarvestChestController:Refresh()
		ClientState.Shop = nil
		Controllers.SeedShopController:Refresh()
		ClientState.Profile.Seeds = {}
		Controllers.SeedShopController:RefreshPouch()
	end)
end
