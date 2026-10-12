-- Owns player profiles: loading (with session locking via ProfileStore), migration,
-- validation, release on leave, and pushing the read-only profile view to the client.
--
-- Other services read/modify profile data only through DataService.getData() and the pure
-- functions in Data/Transactions, then call DataService.markDirty() to sync the client.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = ReplicatedStorage.Config
local GameConfig = require(Config.GameConfig)
local PetConfig = require(Config.PetConfig)
local ItemConfig = require(Config.ItemConfig)
local EggConfig = require(Config.EggConfig)
local CompassConfig = require(Config.CompassConfig)
local ShopConfig = require(Config.ShopConfig)
local ZoneConfig = require(Config.ZoneConfig)
local MountConfig = require(Config.MountConfig)
local RarityConfig = require(Config.RarityConfig)

local Signal = require(ReplicatedStorage.Shared.Signal)
local Odds = require(ReplicatedStorage.Shared.Odds)
local RemoteNames = require(ReplicatedStorage.Shared.RemoteNames)

local Data = ServerScriptService.Data
local ProfileSchema = require(Data.ProfileSchema)
local Migrations = require(Data.Migrations)
local Transactions = require(Data.Transactions)
local ProfileView = require(Data.ProfileView)
local ProfileStoreAdapter = require(Data.ProfileStoreAdapter)
local MountStats = require(script.Parent.MountStats)

local Security = ServerScriptService.Security
local Remotes = require(Security.Remotes)

local DataService = {}
DataService.Name = "DataService"

-- (player, data) after a profile is loaded, migrated and validated.
DataService.ProfileLoaded = Signal.new()
-- (player) just before a profile is released (player leaving).
DataService.ProfileReleasing = Signal.new()

local Services
local adapter
local sessions: { [Player]: any } = {}
local syncQueued: { [Player]: boolean } = {}

local txContext: Transactions.Context
local viewContext: ProfileView.ViewContext
local sanitizeContext: ProfileSchema.SanitizeContext

local function maxSpeedLevel(): number
	for _, product in ShopConfig.Products do
		if product.kind == "SpeedUpgrade" then
			return product.maxLevel or 0
		end
	end
	return 0
end

local function oddsText(eggTier: string, speciesId: string): string
	if eggTier == "StudioKit" then
		return "Studio test kit"
	end
	local tier = EggConfig.Tiers[eggTier]
	if not tier then
		return "Odds unavailable"
	end
	local text = Odds.text(tier.pool, speciesId)
	if not text then
		-- The species is no longer in that egg's pool (config changed since it hatched).
		return `From a {tier.displayName}`
	end
	return `{text} · {tier.displayName}`
end
DataService.oddsText = oddsText

function DataService.speedFor(species: any, upgradeLevel: number): number
	return MountStats.computeSpeed(species, upgradeLevel, MountConfig)
end

-- Public API ---------------------------------------------------------------------------------

-- The live profile data for a player, or nil if not loaded / already released.
function DataService.getData(player: Player): ProfileSchema.ProfileData?
	local session = sessions[player]
	if session == nil or not session:IsActive() then
		return nil
	end
	return session.Data
end

function DataService.context(): Transactions.Context
	return txContext
end

function DataService.buildView(player: Player): ProfileView.ProfileViewData?
	local data = DataService.getData(player)
	if not data then
		return nil
	end
	return ProfileView.build(data, viewContext)
end

-- Coalesces all changes made during this frame into one ProfileSync push.
function DataService.markDirty(player: Player)
	if syncQueued[player] then
		return
	end
	syncQueued[player] = true
	task.defer(function()
		syncQueued[player] = nil
		local view = DataService.buildView(player)
		if view then
			Remotes.fire("ProfileSync", player, view)
		end
	end)
end

-- Loading --------------------------------------------------------------------------------------

local function applyStudioStarterKit(player: Player, session: any)
	local kit = GameConfig.Debug.StudioStarterKit
	if not (kit.Enabled and RunService:IsStudio() and session.IsMock) then
		return
	end
	local data = session.Data
	if data.flags.studioKitGranted then
		return
	end
	data.flags.studioKitGranted = true
	for _, speciesId in kit.Pets do
		Transactions.addPet(data, txContext, speciesId, "StudioKit")
	end
	for itemId, quantity in kit.Items do
		Transactions.addItem(data, txContext, itemId, quantity)
	end
	if kit.Currency > 0 then
		Transactions.addCurrency(data, txContext, kit.Currency)
	end
	print(`[Data] Studio starter kit granted to {player.Name} (mock profile, not saved to live data)`)
end

local function onPlayerAdded(player: Player)
	local key = GameConfig.Data.KeyPrefix .. tostring(player.UserId)
	local session = adapter:startSession(player, key)

	if session == nil then
		if player.Parent == Players then
			-- Never continue with a blank profile: it could overwrite real progress.
			player:Kick("We couldn't load your data safely. Your progress is safe - please rejoin in a moment.")
		end
		return
	end
	if player.Parent ~= Players then
		session:EndSession()
		return
	end

	local data = session.Data
	local migration, version = Migrations.run(data)
	if migration ~= "Ok" then
		warn(`[Data] Profile {key} migration result {migration} at version {version}; releasing untouched`)
		session:EndSession()
		player:Kick(if migration == "Newer"
			then "This server is running an older version of the game. Please rejoin."
			else "Your data needs an update this server can't perform. Please rejoin later.")
		return
	end

	session:Reconcile()
	local notes = ProfileSchema.sanitize(data, sanitizeContext)
	if #notes > 0 then
		warn(`[Data] Repaired profile {key}: {table.concat(notes, "; ")}`)
	end
	session:AddUserId(player.UserId)

	local now = os.time()
	if data.createdAt == 0 then
		data.createdAt = now
	end
	data.lastJoinAt = now

	session.OnSessionEnd:Connect(function()
		sessions[player] = nil
		if player.Parent == Players then
			-- Another server stole the session lock (player joined elsewhere).
			player:Kick("Your profile was opened on another server. Please rejoin.")
		end
	end)

	sessions[player] = session
	applyStudioStarterKit(player, session)

	if session.IsMock then
		print(`[Data] {player.Name} is using a mock profile (Studio): progress is not saved to live data.`)
	end

	DataService.ProfileLoaded:Fire(player, data)
	DataService.markDirty(player)
end

local function onPlayerRemoving(player: Player)
	DataService.ProfileReleasing:Fire(player)
	local session = sessions[player]
	sessions[player] = nil
	syncQueued[player] = nil
	if session then
		-- ProfileStore saves and releases the session lock.
		session:EndSession()
	end
end

-- Lifecycle ------------------------------------------------------------------------------------

function DataService.init(services)
	Services = services

	local knownSpecies = PetConfig.Species
	txContext = {
		Pets = PetConfig.Species,
		Items = ItemConfig.Items,
		Compasses = CompassConfig.Compasses,
		Products = ShopConfig.Products,
		Zones = ZoneConfig.Zones,
		maxPets = GameConfig.MaxPets,
		maxItemStack = GameConfig.MaxItemStack,
		maxCurrency = GameConfig.MaxCurrency,
		speedUpgradePrice = ShopConfig.speedUpgradePrice,
		now = os.time,
		newId = function()
			return HttpService:GenerateGUID(false)
		end,
	}
	viewContext = {
		Pets = PetConfig.Species,
		Items = ItemConfig.Items,
		rarityRank = RarityConfig.rank,
		oddsText = oddsText,
		computeSpeed = DataService.speedFor,
		canFly = MountStats.canFly,
		maxPets = GameConfig.MaxPets,
	}
	sanitizeContext = {
		knownSpecies = knownSpecies,
		knownCompasses = CompassConfig.Compasses,
		maxCurrency = GameConfig.MaxCurrency,
		maxItemStack = GameConfig.MaxItemStack,
		maxSpeedLevel = maxSpeedLevel(),
	}

	local template = ProfileSchema.template(GameConfig.StartingCurrency, ZoneConfig.DefaultUnlocked)
	adapter = ProfileStoreAdapter.new(GameConfig.Data.StoreName, template, GameConfig.Data.UseLiveDataStoreInStudio)
end

function DataService.start()
	local Security = Services.RemoteSecurityService
	Security.bindFunction("RequestSync", { action = "RequestSync", args = {}, lock = false }, function(player)
		local view = DataService.buildView(player)
		if not view then
			return Security.fail(RemoteNames.Codes.NotReady, "Your data is still loading.")
		end
		return Security.ok(view)
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return DataService
