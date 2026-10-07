--!strict
--[[
	SeedService
	Path: ServerScriptService.Server.Services.SeedService

	The player's seed pouch. Seeds are persistent (profile.Seeds) because they are
	bought with permanent Candies; unplanted seeds survive escaping, losing or leaving.
	Also owns the soft-lock guarantee: a player who can neither afford the cheapest seed
	nor owns any seed receives a small starter grant when a match starts.

	Dependencies: CropConfig, EconomyConfig; Registry: DataService, PlayerService

	API:
		SeedService:GetSeedCount(player, seedId) -> number
		SeedService:GetTotalSeeds(player) -> number
		SeedService:AddSeeds(player, seedId, amount, reason) -> boolean
		SeedService:ConsumeSeed(player, seedId) -> boolean
		SeedService:GrantSoftLockIfNeeded(player) -> boolean
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local CropConfig = require(Shared.Config.CropConfig)
local EconomyConfig = require(Shared.Config.EconomyConfig)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)

local SeedService = {}

local cheapestSeedPrice = math.huge
for _, definition in CropConfig.Crops do
	cheapestSeedPrice = math.min(cheapestSeedPrice, definition.SeedPrice)
end

function SeedService:Init() end

function SeedService:GetSeedCount(player: Player, seedId: string): number
	return Services.DataService:GetSeedCount(player, seedId)
end

function SeedService:GetTotalSeeds(player: Player): number
	local data = Services.DataService:GetData(player)
	local total = 0
	if data then
		for _, count in data.Seeds do
			total += count
		end
	end
	return total
end

function SeedService:AddSeeds(player: Player, seedId: string, amount: number, _reason: string): boolean
	if CropConfig.Get(seedId) == nil then
		return false
	end
	return Services.DataService:AddSeeds(player, seedId, amount)
end

function SeedService:ConsumeSeed(player: Player, seedId: string): boolean
	return Services.DataService:ConsumeSeed(player, seedId)
end

function SeedService:GrantSoftLockIfNeeded(player: Player): boolean
	if not Services.DataService:IsLoaded(player) then
		return false
	end
	if Services.DataService:GetCandies(player) >= cheapestSeedPrice or self:GetTotalSeeds(player) > 0 then
		return false
	end
	local grant = EconomyConfig.SoftLockGrant
	if self:AddSeeds(player, grant.SeedId, grant.Quantity, "SoftLockGrant") then
		local definition = CropConfig.Get(grant.SeedId)
		Services.PlayerService:Notify(
			player,
			`The farm spirits left you {grant.Quantity} {definition and definition.DisplayName or grant.SeedId} seeds. Grow, harvest, escape!`,
			"Success",
			6
		)
		return true
	end
	return false
end

return SeedService
