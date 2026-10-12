-- Rolls the reward for a claimed egg with server-side RNG, commits the pet to the player's
-- profile, pays the egg's coin reward, optionally drops the pet's taming item nearby, and
-- tells the client to play the reveal. The reward is committed BEFORE the client animates,
-- so disconnecting mid-animation never loses it (it is in the inventory on rejoin).
--
-- HatchResult payload:
--   { petId, species, displayName, rarity, eggTier, eggName, oddsText, requiredItem,
--     requiredItemName, coins, itemDropped }

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local EggConfig = require(ReplicatedStorage.Config.EggConfig)
local PetConfig = require(ReplicatedStorage.Config.PetConfig)
local ItemConfig = require(ReplicatedStorage.Config.ItemConfig)
local RarityConfig = require(ReplicatedStorage.Config.RarityConfig)
local WeightedRandom = require(ReplicatedStorage.Shared.WeightedRandom)
local Remotes = require(ServerScriptService.Security.Remotes)

local HatchingService = {}
HatchingService.Name = "HatchingService"

local Services
local rng = Random.new()
-- Egg pools with unknown species removed (ConfigValidator reports those at boot).
local validPools: { [string]: WeightedRandom.Pool } = {}

function HatchingService.rollSpecies(eggTier: string): string?
	local pool = validPools[eggTier]
	if not pool then
		return nil
	end
	return WeightedRandom.pick(pool, rng)
end

-- Returns true once the pet has been committed. Must not yield before the commit.
function HatchingService.hatch(player: Player, egg): boolean
	local tier = EggConfig.Tiers[egg.kind]
	local speciesId = HatchingService.rollSpecies(egg.kind)
	if not tier or not speciesId then
		warn(`[Hatch] Egg tier "{egg.kind}" has no valid reward pool`)
		return false
	end

	local pet, code = Services.InventoryService.addPet(player, speciesId, egg.kind)
	if not pet then
		warn(`[Hatch] Could not add {speciesId} for {player.Name}: {code}`)
		return false
	end

	-- Committed. Everything below is a side effect; a failure there must never make the
	-- caller think the hatch failed (that would put the egg back and allow a second reward).
	local ok, err = pcall(HatchingService._afterCommit, player, egg, tier, speciesId, pet)
	if not ok then
		warn(`[Hatch] Post-commit step failed for {player.Name}: {err}`)
	end
	return true
end

function HatchingService._afterCommit(player: Player, egg, tier, speciesId: string, pet)
	local coins = Services.EconomyService.addCurrency(player, tier.coinReward, "EggHatch")
	local species = PetConfig.Species[speciesId]
	local item = ItemConfig.Items[species.requiredItem]

	local itemDropped = false
	if tier.itemDropChance > 0 and rng:NextNumber() < tier.itemDropChance then
		itemDropped = Services.ItemSpawnService.spawnDrop(species.requiredItem, egg.position, egg.zoneId)
	end

	Remotes.fire("HatchResult", player, {
		petId = pet.id,
		species = speciesId,
		displayName = species.displayName,
		rarity = species.rarity,
		eggTier = egg.kind,
		eggName = tier.displayName,
		oddsText = Services.DataService.oddsText(egg.kind, speciesId),
		requiredItem = species.requiredItem,
		requiredItemName = if item then item.displayName else species.requiredItem,
		coins = coins,
		itemDropped = itemDropped,
	})

	local rarity = RarityConfig.Tiers[species.rarity]
	if rarity and rarity.announce then
		Services.NotificationService.broadcast(
			"rare",
			`{player.DisplayName} hatched a {rarity.displayName} {species.displayName}! ({Services.DataService.oddsText(egg.kind, speciesId)})`,
			species.rarity
		)
	end
end

function HatchingService.init(services)
	Services = services
	for tierId, tier in EggConfig.Tiers do
		validPools[tierId] = WeightedRandom.filter(tier.pool, function(speciesId)
			return PetConfig.Species[speciesId] ~= nil
		end)
	end
end

function HatchingService.start() end

return HatchingService
