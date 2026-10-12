-- Spawns eggs in every zone on server timers, expires them, and owns the authoritative egg
-- registry. Egg rarity is a weighted pick from the zone's config. Each egg gets a
-- server-generated id, a ProximityPrompt, and is claimable exactly once.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local EggConfig = require(ReplicatedStorage.Config.EggConfig)
local ZoneConfig = require(ReplicatedStorage.Config.ZoneConfig)
local GameConfig = require(ReplicatedStorage.Config.GameConfig)
local Signal = require(ReplicatedStorage.Shared.Signal)
local WeightedRandom = require(ReplicatedStorage.Shared.WeightedRandom)

local World = ServerScriptService.World
local ClaimRegistry = require(World.ClaimRegistry)
local ZoneRegistry = require(World.ZoneRegistry)
local SpawnPositionFinder = require(World.SpawnPositionFinder)
local AssetLibrary = require(World.AssetLibrary)

local EggSpawnService = {}
EggSpawnService.Name = "EggSpawnService"

EggSpawnService.EggSpawned = Signal.new() -- (record)
EggSpawnService.EggRemoved = Signal.new() -- (eggId, reason: "Claimed" | "Expired")
EggSpawnService.PromptTriggered = Signal.new() -- (player, eggId)

local registry = ClaimRegistry.new()
local rng = Random.new()
local activeFolder: Folder

function EggSpawnService.registry()
	return registry
end

function EggSpawnService.getActive(eggId: string)
	return registry:getActive(eggId)
end

function EggSpawnService.activeEggs()
	return registry:active()
end

local function createPrompt(parent: BasePart, tierId: string, eggId: string)
	local tier = EggConfig.Tiers[tierId]
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "HatchPrompt"
	prompt.ActionText = "Hatch"
	prompt.ObjectText = tier.displayName
	prompt.HoldDuration = tier.holdDuration
	prompt.MaxActivationDistance = GameConfig.Interaction.EggPromptDistance
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.Parent = parent
	-- The egg id is bound here on the server; the client never chooses which egg it claims.
	prompt.Triggered:Connect(function(player)
		EggSpawnService.PromptTriggered:Fire(player, eggId)
	end)
end

local function spawnEgg(zone): boolean
	if registry:count() >= ZoneConfig.GlobalMaxEggs then
		return false
	end
	local zonePart = ZoneRegistry.getPart(zone.id)
	if not zonePart then
		return false
	end
	local tierId = WeightedRandom.pick(zone.eggs.weights, rng)
	if not tierId or not EggConfig.Tiers[tierId] then
		return false
	end
	local position = SpawnPositionFinder.find(zonePart, {
		occupied = registry:positions(),
		minSpacing = zone.eggs.minSpacing,
		rng = rng,
	})
	if not position then
		return false
	end
	local model = AssetLibrary.egg(tierId)
	if not model then
		return false
	end

	local id = HttpService:GenerateGUID(false)
	local now = os.clock()
	local root = model.PrimaryPart :: BasePart
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
	AssetLibrary.placeOnGround(model, position, rng:NextNumber(0, math.pi * 2))
	model.Name = `Egg_{tierId}`
	model:SetAttribute("EggId", id)
	model:SetAttribute("Tier", tierId)
	model:SetAttribute("ZoneId", zone.id)
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	createPrompt(root, tierId, id)
	model.Parent = activeFolder

	local record: ClaimRegistry.Record = {
		id = id,
		kind = tierId,
		zoneId = zone.id,
		position = root.Position,
		spawnedAt = now,
		expiresAt = now + (zone.eggs.despawnSeconds or EggConfig.DefaultDespawnSeconds),
		state = "Active",
		model = model,
	}
	registry:add(record)
	EggSpawnService.EggSpawned:Fire(record)
	return true
end

-- Removes an egg (claimed or expired). Safe to call more than once.
function EggSpawnService.remove(eggId: string, reason: "Claimed" | "Expired")
	local record = registry:remove(eggId, reason)
	if record then
		EggSpawnService.EggRemoved:Fire(eggId, reason)
	end
end

-- Atomically claims an egg for a player. Returns the record (now "Claimed") or nil if the
-- egg no longer exists or someone else got it first.
function EggSpawnService.claim(eggId: string, player: Player)
	return registry:tryClaim(eggId, player.UserId)
end

function EggSpawnService.release(eggId: string)
	registry:release(eggId)
end

local function zoneLoop(zone)
	local eggs = zone.eggs
	local failures = 0
	while true do
		local active = registry:countWhere(function(record)
			return record.zoneId == zone.id
		end)
		local spawned = false
		if active < eggs.maxActive then
			spawned = spawnEgg(zone)
			if spawned then
				failures = 0
			else
				failures += 1
				if failures == 20 then
					warn(`[Eggs] Zone "{zone.id}" keeps failing to find spawn positions; check its region and map geometry`)
				end
			end
		end
		-- Top up quickly below the minimum, then settle to the configured interval.
		if spawned and active + 1 < eggs.minActive then
			task.wait(0.2)
		else
			task.wait(eggs.spawnInterval)
		end
	end
end

function EggSpawnService.init(_services)
	activeFolder = AssetLibrary.workspaceFolder("ActiveEggs")
end

function EggSpawnService.start()
	for _, zone in ZoneConfig.Zones do
		if not ZoneRegistry.getPart(zone.id) then
			warn(`[Eggs] Zone "{zone.id}" has no zone part; no eggs will spawn there`)
			continue
		end
		task.spawn(zoneLoop, zone)
	end

	-- Expiry runs on the server clock; no client needs to be present.
	task.spawn(function()
		while true do
			task.wait(1)
			for _, eggId in registry:expired(os.clock()) do
				EggSpawnService.remove(eggId, "Expired")
			end
		end
	end)
end

return EggSpawnService
