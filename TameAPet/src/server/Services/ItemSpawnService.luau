-- Rare taming items in the world:
--   * zone pickups: each item in ItemConfig spawns in its configured zones on a timer
--   * world drops:  HatchingService may drop the hatched pet's taming item next to the egg
-- Pickups are collected through a server-bound ProximityPrompt and validated here
-- (loaded profile, rate limit, existence, distance, zone pass, stack limit) before the
-- atomic claim. A pickup can only ever be collected once.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Config.GameConfig)
local ItemConfig = require(ReplicatedStorage.Config.ItemConfig)
local PetConfig = require(ReplicatedStorage.Config.PetConfig)
local ZoneConfig = require(ReplicatedStorage.Config.ZoneConfig)

local World = ServerScriptService.World
local ClaimRegistry = require(World.ClaimRegistry)
local ZoneRegistry = require(World.ZoneRegistry)
local SpawnPositionFinder = require(World.SpawnPositionFinder)
local AssetLibrary = require(World.AssetLibrary)

local ItemSpawnService = {}
ItemSpawnService.Name = "ItemSpawnService"

local Services
local registry = ClaimRegistry.new()
local rng = Random.new()
local activeFolder: Folder
local onTriggered: (Player, string) -> ()

local function mapRayParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local list: { Instance } = { workspace.Terrain }
	local map = workspace:FindFirstChild("Map")
	if map then
		table.insert(list, map)
	end
	params.FilterDescendantsInstances = list
	return params
end

local function createPickup(itemId: string, zoneId: string, position: Vector3, isDrop: boolean): boolean
	local item = ItemConfig.Items[itemId]
	if not item then
		warn(`[Items] Cannot spawn unknown item "{itemId}"`)
		return false
	end
	if registry:count() >= ZoneConfig.GlobalMaxItems then
		return false
	end
	local model = AssetLibrary.item(itemId)
	if not model then
		return false -- AssetLibrary already warned
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
	AssetLibrary.placeOnGround(model, position, rng:NextNumber(0, math.pi * 2))

	local id = HttpService:GenerateGUID(false)
	local root = model.PrimaryPart :: BasePart
	model.Name = `Item_{itemId}`
	model:SetAttribute("PickupId", id)
	model:SetAttribute("ItemId", itemId)
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "CollectPrompt"
	prompt.ActionText = "Collect"
	prompt.ObjectText = item.displayName
	prompt.HoldDuration = 0.3
	prompt.MaxActivationDistance = GameConfig.Interaction.ItemPromptDistance
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.Parent = root
	prompt.Triggered:Connect(function(player)
		onTriggered(player, id)
	end)

	model.Parent = activeFolder
	local now = os.clock()
	registry:add({
		id = id,
		kind = itemId,
		zoneId = zoneId,
		isDrop = isDrop,
		position = root.Position,
		spawnedAt = now,
		expiresAt = now + item.spawn.despawnSeconds,
		state = "Active",
		model = model,
		hidden = item.spawn.hidden,
	})
	return true
end

-- World drop next to `near` (e.g. a just-claimed egg). Returns true if it spawned.
function ItemSpawnService.spawnDrop(itemId: string, near: Vector3, zoneId: string): boolean
	if not ItemConfig.Items[itemId] then
		warn(`[Items] Drop requested for unknown item "{itemId}"`)
		return false
	end
	local params = mapRayParams()
	for _ = 1, 8 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * rng:NextNumber(5, 9)
		local result = workspace:Raycast(near + offset + Vector3.new(0, 12, 0), Vector3.new(0, -30, 0), params)
		if result and result.Normal.Y > 0.7 then
			return createPickup(itemId, zoneId, result.Position, true)
		end
	end
	return createPickup(itemId, zoneId, near, true)
end

local function countOf(itemId: string): number
	return registry:countWhere(function(record)
		return record.kind == itemId and not record.isDrop
	end)
end

local function itemLoop(itemId: string, item)
	local spawn = item.spawn
	local zones = {}
	for _, zoneId in spawn.zones do
		if ZoneRegistry.getPart(zoneId) then
			table.insert(zones, zoneId)
		else
			warn(`[Items] Item "{itemId}" is configured for zone "{zoneId}", which does not exist; skipping that zone`)
		end
	end
	if #zones == 0 then
		warn(`[Items] Item "{itemId}" has no valid spawn zones and will only appear as an egg drop`)
		return
	end
	while true do
		if countOf(itemId) < spawn.maxActive then
			local zoneId = zones[rng:NextInteger(1, #zones)]
			local zone = ZoneConfig.get(zoneId)
			local zonePart = ZoneRegistry.getPart(zoneId)
			if zone and zonePart then
				local position = SpawnPositionFinder.find(zonePart, {
					occupied = registry:positions(),
					minSpacing = 15,
					rng = rng,
				})
				if position then
					createPickup(itemId, zoneId, position, false)
				end
			end
		end
		task.wait(spawn.interval)
	end
end

onTriggered = function(player: Player, pickupId: string)
	local Security = Services.RemoteSecurityService
	local Notify = Services.NotificationService

	local allowed, message = Security.checkInteraction(player, "ItemPickup")
	if not allowed then
		if message then
			Notify.notify(player, "error", message)
		end
		return
	end
	local pickup = registry:getActive(pickupId)
	if not pickup then
		Notify.notify(player, "error", "That item is gone.")
		return
	end
	local distance = Security.distanceTo(player, pickup.position)
	local maxDistance = GameConfig.Interaction.ItemPromptDistance + GameConfig.Interaction.DistanceTolerance
	if not distance or distance > maxDistance then
		Security.report(player, "ItemPickup", "too far from pickup")
		return
	end
	local data = Services.DataService.getData(player)
	if not data then
		return
	end
	local zoneId = pickup.zoneId
	if ZoneConfig.get(zoneId) and not ZoneRegistry.isUnlocked(data, zoneId) then
		Notify.notify(player, "error", "You need this zone's pass (Shop) to collect items here.")
		return
	end
	local itemId = pickup.kind
	local item = ItemConfig.Items[itemId]
	if not Services.InventoryService.canAddItem(player, itemId) then
		Notify.notify(player, "error", `You can't carry more {item and item.displayName or itemId}.`)
		return
	end

	local claimed = registry:tryClaim(pickupId, player.UserId)
	if not claimed then
		Notify.notify(player, "error", "Someone else grabbed it first!")
		return
	end
	local added = Services.InventoryService.addItem(player, itemId, 1)
	if added <= 0 then
		registry:release(pickupId)
		Notify.notify(player, "error", "Couldn't collect that item.")
		return
	end
	registry:remove(pickupId, "Claimed")

	Services.EconomyService.addCurrency(player, item.coinReward, "ItemPickup")
	-- Mention which of the player's untamed pets this item is for.
	local forPet: string? = nil
	for _, pet in data.pets do
		local species = PetConfig.Species[pet.species]
		if pet.status == "Untamed" and species and species.requiredItem == itemId then
			forPet = species.displayName
			break
		end
	end
	local suffix = if forPet then ` You can now tame your {forPet}!` else ""
	Notify.notify(player, "success", `Found a {item.displayName}!{suffix}`, item.rarity)
end

function ItemSpawnService.init(services)
	Services = services
	activeFolder = AssetLibrary.workspaceFolder("ActiveItemPickups")
end

function ItemSpawnService.start()
	for itemId, item in ItemConfig.Items do
		task.spawn(itemLoop, itemId, item)
	end
	task.spawn(function()
		while true do
			task.wait(1)
			for _, id in registry:expired(os.clock()) do
				registry:remove(id, "Expired")
			end
		end
	end)
end

return ItemSpawnService
