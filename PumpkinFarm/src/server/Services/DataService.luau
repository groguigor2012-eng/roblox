--!strict
--[[
	DataService
	Path: ServerScriptService.Server.Services.DataService

	The only gateway to persistent player data. Gameplay systems call these methods;
	none of them touch DataStores or profile tables directly.

	Responsibilities:
	  * load a profile on join (via ProfileServiceWrapper), run Migrations, reconcile
	    the template, mark the player's ProfileStatus attribute
	  * keep a failed load in a SAFE state: no profile => every reward/purchase method
	    returns false, the player is told why and cannot queue for matches
	  * transactional mutation (Update): a mutator that errors is rolled back
	  * replicate a read-only ProfileView and the Candies attribute after changes
	    (coalesced to one send per frame)
	  * autosave, release on leave, release everything on server shutdown
	  * kick the player if their session is taken over by another server, so two
	    servers can never write the same profile

	Dependencies: ProfileServiceWrapper, ProfileTemplate, Migrations, DataConfig,
	              TableUtil, Signal, Attributes; Registry: RemoteService

	API:
		DataService:LoadProfileAsync(player) -> (boolean, string?)
		DataService:ReleaseProfile(player)
		DataService:IsLoaded(player) -> boolean
		DataService:GetProfile(player) -> Profile?
		DataService:GetData(player) -> data?          -- read only: mutate through Update
		DataService:Update(player, mutator(data) -> any?) -> (boolean, any?)
		DataService:RequestSave(player)
		DataService:GetCandies(player) -> number
		DataService:AddCandies(player, amount) -> boolean
		DataService:SpendCandies(player, amount) -> boolean
		DataService:OwnsCostume(player, costumeId) -> boolean
		DataService:UnlockCostume(player, costumeId) -> boolean
		DataService:SetEquippedCostume(player, costumeId) -> boolean
		DataService:GetSeedCount(player, seedId) -> number
		DataService:AddSeeds(player, seedId, amount) -> boolean
		DataService:ConsumeSeed(player, seedId) -> boolean
		DataService:GetUpgradeLevel(player, upgradeId) -> number
		DataService:SetUpgradeLevel(player, upgradeId, level) -> boolean
		DataService:IncrementStatistic(player, statName, amount) -> boolean
		DataService:RecordHighestWave(player, wave)
		DataService:RecordClassMatch(player, classId, kills, wave)
		DataService:SetSetting(player, key, value) -> boolean
		DataService:GetProfileView(player) -> ProfileView?
		DataService.ProfileLoaded : Signal(player)
		DataService.ProfileChanged : Signal(player)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local ClassConfig = require(Shared.Config.ClassConfig)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local Signal = require(Shared.Classes.Signal)
local TableUtil = require(Shared.Utilities.TableUtil)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local DataConfig = require(Server.Data.DataConfig)
local Migrations = require(Server.Data.Migrations)
local ProfileServiceWrapper = require(Server.Data.ProfileServiceWrapper)
local ProfileTemplate = require(Server.Data.ProfileTemplate)

local DataService = {}
DataService.ProfileLoaded = Signal.new()
DataService.ProfileChanged = Signal.new()

local store: any = nil
local profiles: { [Player]: any } = {}
local pendingReplication: { [Player]: boolean } = {}
local replicationScheduled = false

local STATISTIC_KEYS = {
	TotalWaves = true,
	TotalKills = true,
	TotalHarvested = true,
	BossesDefeated = true,
	MatchesPlayed = true,
	MatchesEscaped = true,
}

local function isPositiveInteger(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value % 1 == 0 and value < math.huge
end

local function flushReplication()
	replicationScheduled = false
	for player in pendingReplication do
		pendingReplication[player] = nil
		if player.Parent == Players and profiles[player] then
			local view = DataService:GetProfileView(player)
			player:SetAttribute(Attributes.Candies, view and view.Candies or 0)
			Services.RemoteService:FireClient("ProfileUpdated", player, view)
		end
	end
end

local function markChanged(player: Player)
	pendingReplication[player] = true
	if not replicationScheduled then
		replicationScheduled = true
		task.defer(flushReplication)
	end
	DataService.ProfileChanged:Fire(player)
end

function DataService:Init()
	store = ProfileServiceWrapper.GetStore(ProfileTemplate)
	print(`[DataService] persistence backend: {store.BackendName}`)
end

function DataService:Start()
	-- Autosave refreshes session locks; the wrapper skips passes when budget is low.
	task.spawn(function()
		while true do
			task.wait(DataConfig.AutoSaveInterval)
			local ok, err = pcall(function()
				store:SaveAllAsync()
			end)
			if not ok then
				warn(`[DataService] autosave pass failed: {err}`)
			end
		end
	end)

	game:BindToClose(function()
		if RunService:IsStudio() and store.BackendName == "Memory" then
			return
		end
		store:ReleaseAllAsync(DataConfig.ShutdownTimeout)
	end)
end

function DataService:LoadProfileAsync(player: Player): (boolean, string?)
	if profiles[player] then
		return true, nil
	end
	player:SetAttribute(Attributes.ProfileStatus, "Loading")

	local profile, problem = store:LoadProfileAsync(player.UserId)
	if profile == nil then
		player:SetAttribute(Attributes.ProfileStatus, "Failed")
		return false, problem or "unknown error"
	end

	if player.Parent ~= Players then
		-- Player left while the profile was loading: release immediately.
		profile:Release()
		return false, "player left during load"
	end

	local migrated, reason = Migrations.Run(profile.Data)
	if not migrated then
		-- Refuse to use (and therefore to overwrite) data we cannot understand.
		warn(`[DataService] migration failed for {player.UserId}: {reason}`)
		profile:Release()
		player:SetAttribute(Attributes.ProfileStatus, "Failed")
		return false, reason
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()

	-- Every class flagged DefaultUnlocked is owned, even if added after the profile
	-- was created (reconcile alone does not add keys into existing sets).
	for classId, definition in ClassConfig.Classes do
		if definition.DefaultUnlocked then
			profile.Data.UnlockedCostumes[classId] = true
		end
	end

	profile:ListenToRelease(function(_releaseReason: string)
		-- ReleaseProfile clears the entry before releasing, so if it is still ours the
		-- release came from elsewhere (session taken by another server, or a backend
		-- shutdown). The player must not keep playing without a writable profile.
		if profiles[player] == profile then
			profiles[player] = nil
			if player.Parent == Players then
				player:Kick("Your data was loaded on another server. Please rejoin.")
			end
		end
	end)

	profiles[player] = profile
	player:SetAttribute(Attributes.ProfileStatus, if profile.IsTemporary then "Temporary" else "Loaded")
	markChanged(player)
	DataService.ProfileLoaded:Fire(player)
	return true, nil
end

function DataService:ReleaseProfile(player: Player)
	local profile = profiles[player]
	if profile then
		profiles[player] = nil
		pendingReplication[player] = nil
		profile:Release()
	end
end

function DataService:IsLoaded(player: Player): boolean
	local profile = profiles[player]
	return profile ~= nil and profile:IsActive()
end

function DataService:GetProfile(player: Player): any
	return profiles[player]
end

function DataService:GetData(player: Player): any
	local profile = profiles[player]
	if profile and profile:IsActive() then
		return profile.Data
	end
	return nil
end

-- Runs `mutator` against the live data. If it throws, the data is restored from a
-- snapshot so a half-applied change can never be saved.
function DataService:Update(player: Player, mutator: (data: any) -> any): (boolean, any)
	local data = self:GetData(player)
	if data == nil then
		return false, nil
	end
	local snapshot = TableUtil.DeepCopy(data)
	local ok, result = pcall(mutator, data)
	if not ok then
		warn(`[DataService] mutation failed for {player.UserId}, rolled back: {result}`)
		table.clear(data)
		for key, value in snapshot do
			data[key] = value
		end
		return false, nil
	end
	markChanged(player)
	return true, result
end

function DataService:RequestSave(player: Player)
	local profile = profiles[player]
	if profile then
		profile:Save()
	end
end

-- Candies ----------------------------------------------------------------------------

function DataService:GetCandies(player: Player): number
	local data = self:GetData(player)
	return if data then data.Candies else 0
end

function DataService:AddCandies(player: Player, amount: number): boolean
	if not isPositiveInteger(amount) then
		return false
	end
	local ok = self:Update(player, function(data)
		data.Candies = math.min(EconomyConfig.Candies.Max, data.Candies + amount)
	end)
	return ok
end

function DataService:SpendCandies(player: Player, amount: number): boolean
	if not isPositiveInteger(amount) then
		return false
	end
	local data = self:GetData(player)
	if data == nil or data.Candies < amount then
		return false
	end
	local ok = self:Update(player, function(d)
		d.Candies -= amount
	end)
	return ok
end

-- Costumes ----------------------------------------------------------------------------

function DataService:OwnsCostume(player: Player, costumeId: string): boolean
	local data = self:GetData(player)
	return data ~= nil and data.UnlockedCostumes[costumeId] == true
end

function DataService:UnlockCostume(player: Player, costumeId: string): boolean
	if ClassConfig.Get(costumeId) == nil then
		return false
	end
	local ok = self:Update(player, function(data)
		data.UnlockedCostumes[costumeId] = true
	end)
	return ok
end

function DataService:SetEquippedCostume(player: Player, costumeId: string): boolean
	if not self:OwnsCostume(player, costumeId) then
		return false
	end
	local ok = self:Update(player, function(data)
		data.EquippedCostume = costumeId
	end)
	return ok
end

-- Seeds -------------------------------------------------------------------------------

function DataService:GetSeedCount(player: Player, seedId: string): number
	local data = self:GetData(player)
	return if data then (data.Seeds[seedId] or 0) else 0
end

function DataService:AddSeeds(player: Player, seedId: string, amount: number): boolean
	if not isPositiveInteger(amount) then
		return false
	end
	local ok = self:Update(player, function(data)
		data.Seeds[seedId] = (data.Seeds[seedId] or 0) + amount
	end)
	return ok
end

function DataService:ConsumeSeed(player: Player, seedId: string): boolean
	if self:GetSeedCount(player, seedId) < 1 then
		return false
	end
	local ok = self:Update(player, function(data)
		local remaining = data.Seeds[seedId] - 1
		data.Seeds[seedId] = if remaining > 0 then remaining else nil
	end)
	return ok
end

-- Upgrades ----------------------------------------------------------------------------

function DataService:GetUpgradeLevel(player: Player, upgradeId: string): number
	local data = self:GetData(player)
	return if data then (data.PermanentUpgrades[upgradeId] or 0) else 0
end

function DataService:SetUpgradeLevel(player: Player, upgradeId: string, level: number): boolean
	if type(level) ~= "number" or level < 0 or level % 1 ~= 0 then
		return false
	end
	local ok = self:Update(player, function(data)
		data.PermanentUpgrades[upgradeId] = level
	end)
	return ok
end

-- Statistics --------------------------------------------------------------------------

function DataService:IncrementStatistic(player: Player, statName: string, amount: number): boolean
	if not STATISTIC_KEYS[statName] or not isPositiveInteger(amount) then
		return false
	end
	local ok = self:Update(player, function(data)
		data.Statistics[statName] += amount
	end)
	return ok
end

function DataService:RecordHighestWave(player: Player, wave: number)
	local data = self:GetData(player)
	if data and wave > data.Statistics.HighestWave then
		self:Update(player, function(d)
			d.Statistics.HighestWave = wave
		end)
	end
end

function DataService:RecordClassMatch(player: Player, classId: string, kills: number, wave: number)
	if ClassConfig.Get(classId) == nil then
		return
	end
	self:Update(player, function(data)
		local stats = data.ClassStats[classId]
		if stats == nil then
			stats = { MatchesPlayed = 0, Kills = 0, HighestWave = 0 }
			data.ClassStats[classId] = stats
		end
		stats.MatchesPlayed += 1
		stats.Kills += math.max(0, math.floor(kills))
		stats.HighestWave = math.max(stats.HighestWave, wave)
	end)
end

-- Settings ----------------------------------------------------------------------------

function DataService:SetSetting(player: Player, key: string, value: boolean): boolean
	local data = self:GetData(player)
	if data == nil or type(data.Settings[key]) ~= "boolean" or type(value) ~= "boolean" then
		return false
	end
	local ok = self:Update(player, function(d)
		d.Settings[key] = value
	end)
	return ok
end

-- Replication -------------------------------------------------------------------------

function DataService:GetProfileView(player: Player): any
	local profile = profiles[player]
	if profile == nil then
		return nil
	end
	local data = profile.Data
	return {
		Candies = data.Candies,
		UnlockedCostumes = TableUtil.DeepCopy(data.UnlockedCostumes),
		EquippedCostume = data.EquippedCostume or ClassConfig.DefaultClassId,
		Seeds = TableUtil.DeepCopy(data.Seeds),
		PermanentUpgrades = TableUtil.DeepCopy(data.PermanentUpgrades),
		Statistics = TableUtil.DeepCopy(data.Statistics),
		Settings = TableUtil.DeepCopy(data.Settings),
		IsTemporary = profile.IsTemporary == true,
	}
end

return DataService
