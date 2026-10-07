--!strict
--[[
	ClassConfig
	Path: ReplicatedStorage.Shared.Config.ClassConfig

	Permanent costumes that double as combat classes. Ownership lives in the player
	profile (UnlockedCostumes); ClassService validates ownership on the server before a
	class can be equipped, and applies BaseStats + the weapon on every spawn.

	Adding a class: add an entry here, add its weapon to WeaponConfig, and (if the weapon
	uses a new Kind) a module in ServerScriptService.Server.Classes.Weapons. PlayerService,
	ClassService and the UI need no changes.

	Dependencies: Shared.Utilities.TableUtil
]]

local TableUtil = require(script.Parent.Parent.Utilities.TableUtil)

export type ClassDefinition = {
	Id: string,
	DisplayName: string,
	Description: string,
	Role: string,
	WeaponId: string,
	AbilityId: string,
	Price: number,
	DefaultUnlocked: boolean,
	BaseStats: {
		MaxHealth: number,
		WalkSpeed: number,
		JumpHeight: number,
		DamageTakenMultiplier: number,
	},
	Costume: {
		PrimaryColor: Color3,
		SecondaryColor: Color3,
		AccentColor: Color3,
		Hat: string,
	},
	Icon: string,
	SortOrder: number,
}

local Classes: { [string]: ClassDefinition } = {
	Knight = {
		Id = "Knight",
		DisplayName = "Knight",
		Description = "A sturdy reaper-knight. Cleaves through crowds with a huge scythe and shrugs off hits.",
		Role = "High-cleave melee",
		WeaponId = "ReaperScythe",
		AbilityId = "ReapingWhirl",
		Price = 0,
		DefaultUnlocked = true,
		BaseStats = {
			MaxHealth = 150,
			WalkSpeed = 16,
			JumpHeight = 7.2,
			DamageTakenMultiplier = 0.85,
		},
		Costume = {
			PrimaryColor = Color3.fromRGB(170, 176, 190),
			SecondaryColor = Color3.fromRGB(60, 70, 110),
			AccentColor = Color3.fromRGB(255, 150, 30),
			Hat = "Helmet",
		},
		Icon = "🛡️",
		SortOrder = 1,
	},
	Witch = {
		Id = "Witch",
		DisplayName = "Witch",
		Description = "Hurls exploding hexes from a magic staff. Fragile, but wipes out whole groups.",
		Role = "Area damage / crowd control",
		WeaponId = "MagicStaff",
		AbilityId = "HexNova",
		Price = 750,
		DefaultUnlocked = false,
		BaseStats = {
			MaxHealth = 100,
			WalkSpeed = 17,
			JumpHeight = 7.2,
			DamageTakenMultiplier = 1,
		},
		Costume = {
			PrimaryColor = Color3.fromRGB(90, 40, 140),
			SecondaryColor = Color3.fromRGB(30, 20, 40),
			AccentColor = Color3.fromRGB(120, 255, 150),
			Hat = "WitchHat",
		},
		Icon = "🧹",
		SortOrder = 2,
	},
}

local ClassConfig = {
	Classes = Classes,
	DefaultClassId = "Knight",
}

function ClassConfig.Get(classId: string): ClassDefinition?
	return Classes[classId]
end

return TableUtil.DeepFreeze(ClassConfig)
