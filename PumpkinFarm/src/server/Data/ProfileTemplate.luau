--!strict
--[[
	ProfileTemplate
	Path: ServerScriptService.Server.Data.ProfileTemplate

	The default persistent profile. New players get a deep copy; existing profiles are
	migrated (Migrations) and then reconciled against this template so newly added keys
	appear without overwriting anything the player already has.

	Notes:
	- EquippedCostume is intentionally absent (nil): ClassService resolves nil to
	  ClassConfig.DefaultClassId, so changing the default class later needs no migration.
	- UnlockedCostumes is a set: { [costumeId] = true }.
	- Seeds is the permanent seed pouch: { [seedId] = count }. Seeds bought in a match are
	  paid with Candies and persist, so unplanted seeds are never lost.
	- Version must equal Migrations.CurrentVersion.
]]

local ClassConfig = require(game:GetService("ReplicatedStorage").Shared.Config.ClassConfig)

local unlocked: { [string]: boolean } = {}
for classId, definition in ClassConfig.Classes do
	if definition.DefaultUnlocked then
		unlocked[classId] = true
	end
end

local ProfileTemplate = {
	Candies = 120,

	UnlockedCostumes = unlocked,

	EquippedCostume = nil,

	Seeds = {
		NeonStarFruit = 3,
	},

	ClassStats = {},

	PermanentUpgrades = {},

	Statistics = {
		TotalWaves = 0,
		TotalKills = 0,
		TotalHarvested = 0,
		BossesDefeated = 0,
		MatchesPlayed = 0,
		MatchesEscaped = 0,
		HighestWave = 0,
	},

	Settings = {
		MusicEnabled = true,
		EffectsEnabled = true,
	},

	Version = 1,
}

return ProfileTemplate
