--!strict
-- Server half of the collectible system. One service handles every item
-- tagged "Collectible"; items carry attributes, never scripts.
--
-- Registration: existing tagged instances (GetTagged) plus runtime
-- additions/removals (tag signals). Attribute edits re-validate the item.
--
-- Pickup pipeline (CollectRequest):
--   rate limit -> payload shape -> registered + inside Workspace.Collectibles
--   -> data ready -> character alive -> server-measured distance
--   -> claim + grant via ProgressionService (no yields in between)
--   -> CollectResult to the requesting client only.
-- The client sends only the Instance it wants. Type and amount always come
-- from the server's registry.
--
-- Modes:
--   PerPlayer (default) each player collects the item once; others still
--                       see it. Persistent ids are saved; Persistent=false
--                       ids reset each server session.
--   Shared              first player to touch it gets it; the server sets
--                       Available=false for everyone and, if
--                       RespawnSeconds > 0, back to true later.
-- Items without a valid CollectibleId still work as PerPlayer, but only once
-- per player per server session, and are never saved (a generated id would
-- not identify the same item next time). A warning names each one.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local CollectibleConfig = require(Shared.Config.CollectibleConfig)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Utilities.Logger)
local ResourceCleanup = require(Shared.Utilities.ResourceCleanup)
local Types = require(Shared.Types)

local Utilities = script.Parent.Parent.Utilities
local DataSchema = require(Utilities.DataSchema)
local RateLimiter = require(Utilities.RateLimiter)

local CharacterService = require(script.Parent.CharacterService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local ProgressionService = require(script.Parent.ProgressionService)

type CurrencyType = Types.CurrencyType
type CollectMode = Types.CollectMode
type CollectResult = Types.CollectResult

type Record = {
	Instance: PVInstance,
	Key: string,
	StableId: string?,
	CurrencyType: CurrencyType,
	Amount: number,
	Persistent: boolean,
	Mode: CollectMode,
	RespawnSeconds: number,
	Available: boolean,
	RespawnToken: number,
}

local TAG = GameConfig.Tags.Collectible
local ATTR = CollectibleConfig.Attributes
local REWARD_SOURCE = "Collectible"

-- Attribute edits that change how an item behaves (Available is ours).
local WATCHED_ATTRIBUTES: { [string]: boolean } = {
	[ATTR.Id] = true,
	[ATTR.Type] = true,
	[ATTR.Reward] = true,
	[ATTR.Persistent] = true,
	[ATTR.Mode] = true,
	[ATTR.RespawnSeconds] = true,
}

local logger = Logger.new("CollectibleService")

local CollectibleService = {}

local registry: { [Instance]: Record } = {}
local watchers: { [Instance]: ResourceCleanup.ResourceCleanup } = {}
local idOwners: { [string]: Instance } = {}
local runtimeKeyCounter = 0
local remotes: Types.Remotes? = nil
local collectiblesFolder: Instance? = nil
local rateLimiter = RateLimiter.new(
	CollectibleConfig.Collection.RateCapacity,
	CollectibleConfig.Collection.RateRefillPerSecond
)
local started = false

local function isInExpectedHierarchy(instance: Instance): boolean
	if CollectibleConfig.Collection.RequireCollectiblesFolder then
		return collectiblesFolder ~= nil and instance:IsDescendantOf(collectiblesFolder)
	end
	return instance:IsDescendantOf(Workspace)
end

local function normalizePhysics(instance: Instance)
	local function apply(part: BasePart)
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
	end
	if instance:IsA("BasePart") then
		apply(instance)
	end
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			apply(descendant)
		end
	end
end

-- Builds a record from attributes, or returns a reason it is malformed.
local function parse(instance: Instance, previous: Record?): (Record?, string?)
	if not instance:IsA("BasePart") and not instance:IsA("Model") then
		return nil, "must be a BasePart or Model"
	end
	local pvInstance = instance :: PVInstance

	local currencyType = instance:GetAttribute(ATTR.Type)
	if not DataSchema.IsCurrencyType(currencyType) then
		return nil, `{ATTR.Type} must be "Shards" or "PowerOrbs" (got {tostring(currencyType)})`
	end
	local currency: CurrencyType = if currencyType == "Shards" then "Shards" else "PowerOrbs"

	local amount = instance:GetAttribute(ATTR.Reward)
	if amount == nil then
		amount = CollectibleConfig.DefaultRewards[currency]
	end
	if
		type(amount) ~= "number"
		or amount ~= math.floor(amount)
		or amount < 1
		or amount > CollectibleConfig.MaxRewardAmount
	then
		return nil, `{ATTR.Reward} must be an integer 1..{CollectibleConfig.MaxRewardAmount}`
	end

	local mode = instance:GetAttribute(ATTR.Mode)
	if mode == nil then
		mode = "PerPlayer"
	elseif mode ~= "PerPlayer" and mode ~= "Shared" then
		return nil, `{ATTR.Mode} must be "PerPlayer" or "Shared"`
	end

	local persistent = instance:GetAttribute(ATTR.Persistent)
	if persistent == nil then
		persistent = true
	elseif type(persistent) ~= "boolean" then
		return nil, `{ATTR.Persistent} must be a boolean`
	end

	local respawnSeconds = instance:GetAttribute(ATTR.RespawnSeconds)
	if respawnSeconds == nil then
		respawnSeconds = 0
	elseif type(respawnSeconds) ~= "number" or respawnSeconds ~= respawnSeconds or respawnSeconds < 0 then
		return nil, `{ATTR.RespawnSeconds} must be a number >= 0`
	end

	local id = instance:GetAttribute(ATTR.Id)
	local stableId: string? = nil
	if id ~= nil then
		if not DataSchema.IsValidCollectibleId(id) then
			return nil, `{ATTR.Id} must match {CollectibleConfig.Ids.Pattern} and be at most {CollectibleConfig.Ids.MaxLength} chars`
		end
		local idString = id :: string
		local owner = idOwners[idString]
		if owner and not rawequal(owner, instance) then
			return nil, `duplicate {ATTR.Id} "{idString}" (already used by {owner:GetFullName()})`
		end
		stableId = idString
	end

	local key: string
	if stableId then
		key = stableId
	elseif previous and previous.StableId == nil then
		key = previous.Key
	else
		runtimeKeyCounter += 1
		key = `{ProgressionService.RuntimeKeyPrefix}{runtimeKeyCounter}`
	end

	return {
		Instance = pvInstance,
		Key = key,
		StableId = stableId,
		CurrencyType = currency,
		Amount = amount :: number,
		-- Shared items are global and respawn; per-player persistence does not apply.
		Persistent = mode == "PerPlayer" and stableId ~= nil and persistent == true,
		Mode = mode :: CollectMode,
		RespawnSeconds = respawnSeconds :: number,
		Available = if previous then previous.Available else true,
		RespawnToken = if previous then previous.RespawnToken else 0,
	},
		nil
end

local function refresh(instance: Instance)
	local previous = registry[instance]
	if previous and previous.StableId and idOwners[previous.StableId] == instance then
		idOwners[previous.StableId] = nil
	end
	registry[instance] = nil

	local record, problem = parse(instance, previous)
	if not record then
		logger:Warn("InvalidCollectible", { Instance = instance, Problem = problem })
		return
	end
	if not record.StableId then
		logger:Warn("MissingCollectibleId", {
			Instance = instance,
			Fallback = "collectible once per player per server session, not saved",
		})
	end
	if not isInExpectedHierarchy(instance) then
		logger:Warn("CollectibleOutsideFolder", {
			Instance = instance,
			Expected = `Workspace.{GameConfig.Folders.Collectibles}`,
			Effect = "pickup requests for it are rejected",
		})
	end
	if record.StableId then
		idOwners[record.StableId] = instance
	end
	if record.Mode == "Shared" then
		instance:SetAttribute(ATTR.Available, record.Available)
	else
		record.Available = true
		instance:SetAttribute(ATTR.Available, nil)
	end
	registry[instance] = record
end

local function register(instance: Instance)
	if watchers[instance] then
		return
	end
	local cleanup = ResourceCleanup.new(`Collectible:{instance.Name}`)
	watchers[instance] = cleanup
	cleanup:Connect(instance.AttributeChanged, function(attribute: string)
		if WATCHED_ATTRIBUTES[attribute] then
			refresh(instance)
		end
	end)
	normalizePhysics(instance)
	refresh(instance)
end

local function unregister(instance: Instance)
	local cleanup = watchers[instance]
	watchers[instance] = nil
	if cleanup then
		cleanup:Destroy()
	end
	local record = registry[instance]
	registry[instance] = nil
	if record and record.StableId and idOwners[record.StableId] == instance then
		idOwners[record.StableId] = nil
	end
end

local function reply(player: Player, result: CollectResult)
	(remotes :: Types.Remotes).CollectResult:FireClient(player, result)
end

local function fail(player: Player, target: Instance?, reason: string)
	logger:Debug("CollectRejected", { UserId = player.UserId, Target = target, Reason = reason })
	reply(player, { Success = false, Instance = target, Reason = reason })
end

local function scheduleRespawn(record: Record)
	if record.RespawnSeconds <= 0 then
		return
	end
	record.RespawnToken += 1
	local token = record.RespawnToken
	task.delay(record.RespawnSeconds, function()
		local instance = record.Instance
		local current = registry[instance]
		if current and current.RespawnToken == token and current.Mode == "Shared" then
			current.Available = true
			instance:SetAttribute(ATTR.Available, true)
		end
	end)
end

local function onCollectRequest(player: Player, ...: any)
	if not rateLimiter:Allow(player) then
		logger:Debug("CollectRateLimited", { UserId = player.UserId })
		return
	end
	if select("#", ...) ~= 1 then
		fail(player, nil, "BadPayload")
		return
	end
	local target = ...
	if typeof(target) ~= "Instance" then
		fail(player, nil, "BadPayload")
		return
	end
	local record = registry[target]
	if not record or not isInExpectedHierarchy(target) then
		fail(player, target, "NotCollectible")
		return
	end
	if not PlayerDataService.IsPlayerDataReady(player) then
		fail(player, target, "DataNotReady")
		return
	end
	local character = CharacterService.GetAliveRecord(player)
	if not character then
		fail(player, target, "NotAlive")
		return
	end

	local size = if target:IsA("BasePart") then target.Size else (target :: Model):GetExtentsSize()
	local allowed = CollectibleConfig.Collection.ServerCollectRadius + math.max(size.X, size.Y, size.Z) / 2
	local distance = (character.RootPart.Position - record.Instance:GetPivot().Position).Magnitude
	if distance > allowed then
		fail(player, target, "TooFar")
		return
	end

	local result
	if record.Mode == "Shared" then
		if not record.Available then
			fail(player, target, "Unavailable")
			return
		end
		result = ProgressionService.GrantCurrency(player, record.CurrencyType, record.Amount, REWARD_SOURCE)
		if result.Success then
			record.Available = false
			target:SetAttribute(ATTR.Available, false)
			scheduleRespawn(record)
		end
	else
		result = ProgressionService.ClaimCollectible(player, {
			Key = record.Key,
			Persistent = record.Persistent,
			CurrencyType = record.CurrencyType,
			Amount = record.Amount,
			Source = REWARD_SOURCE,
		})
	end

	if not result.Success then
		fail(player, target, result.Reason or "Rejected")
		return
	end
	reply(player, {
		Success = true,
		Instance = target,
		CollectibleId = record.StableId,
		CurrencyType = record.CurrencyType,
		Amount = record.Amount,
		NewTotal = result.NewTotal,
	})
end

function CollectibleService.Init(remoteTable: Types.Remotes)
	remotes = remoteTable
end

function CollectibleService.Start()
	assert(not started, "CollectibleService already started")
	assert(remotes, "CollectibleService.Init must run before Start")
	started = true

	local folder = Workspace:FindFirstChild(GameConfig.Folders.Collectibles)
	if not folder then
		local newFolder = Instance.new("Folder")
		newFolder.Name = GameConfig.Folders.Collectibles
		newFolder.Parent = Workspace
		folder = newFolder
	end
	collectiblesFolder = folder

	CollectionService:GetInstanceAddedSignal(TAG):Connect(register)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unregister)
	for _, instance in CollectionService:GetTagged(TAG) do
		register(instance)
	end

	local remoteTable = remotes :: Types.Remotes
	remoteTable.CollectRequest.OnServerEvent:Connect(onCollectRequest)

	PlayerDataService.OnPlayerDataReady(function(player)
		local state: Types.CollectionState = { CollectedIds = ProgressionService.GetClaimedIds(player) }
		remoteTable.CollectionState:FireClient(player, state)
	end)
	Players.PlayerRemoving:Connect(function(player)
		rateLimiter:Remove(player)
	end)
end

return CollectibleService
