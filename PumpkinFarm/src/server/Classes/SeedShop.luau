--!strict
--[[
	SeedShop
	Path: ServerScriptService.Server.Classes.SeedShop

	Per-match seed stock. Generation is a pure function of (Random, context) so it is
	deterministic for a given match seed and covered by unit tests. The purchase API is
	split into Check + Commit; SeedShopService calls both without yielding in between,
	which makes each purchase atomic under Luau's single-threaded scheduler.

	Every restock bumps Version. Clients must send the version they saw, so a purchase
	racing a restock is rejected with StockChanged instead of buying at a new price.

	Dependencies: SeedConfig, CropConfig, WeightedRandom, MathUtil, ResultCode, Clock

	API:
		SeedShop.GenerateStock(rng, context) -> { Entry }      (static, pure)
		SeedShop.new() -> SeedShop
		shop:Restock(rng, context)
		shop:CheckPurchase(userId, seedId, version) -> (boolean, code, entry?)
		shop:CommitPurchase(userId, seedId)
		shop:Snapshot(userId, open) -> ShopSnapshot
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Clock = require(Shared.Utilities.Clock)
local CropConfig = require(Shared.Config.CropConfig)
local MathUtil = require(Shared.Utilities.MathUtil)
local ResultCode = require(Shared.Constants.ResultCode)
local SeedConfig = require(Shared.Config.SeedConfig)
local WeightedRandom = require(Shared.Utilities.WeightedRandom)

export type Entry = { SeedId: string, Quantity: number, Price: number, PerPlayerLimit: number? }
export type Context = { Wave: number, ContinueLevel: number, PlayerCount: number }

local SeedShop = {}
SeedShop.__index = SeedShop

local function rollEntry(seedId: string, rule: any, rng: Random, context: Context): Entry
	local crop = CropConfig.Get(seedId)
	assert(crop, `[SeedShop] seed {seedId} has no crop definition`)
	local baseQuantity = rng:NextInteger(rule.Quantity[1], rule.Quantity[2])
	local quantity = math.max(1, math.floor(baseQuantity * (1 + SeedConfig.QuantityPerExtraPlayer * (context.PlayerCount - 1))))
	local variance = rule.PriceVariance[1] + rng:NextNumber() * (rule.PriceVariance[2] - rule.PriceVariance[1])
	local price = math.max(SeedConfig.PriceRoundTo, MathUtil.RoundTo(crop.SeedPrice * variance, SeedConfig.PriceRoundTo))
	return { SeedId = seedId, Quantity = quantity, Price = price, PerPlayerLimit = rule.PerPlayerLimit }
end

function SeedShop.GenerateStock(rng: Random, context: Context): { Entry }
	local entries: { Entry } = {}
	local guaranteed: { string } = {}
	local candidates: { string } = {}

	-- Iterate in a stable order so the same seed always yields the same stock.
	local ids = {}
	for seedId in SeedConfig.Seeds do
		table.insert(ids, seedId)
	end
	table.sort(ids)

	for _, seedId in ids do
		local rule = SeedConfig.Seeds[seedId]
		if rule.AlwaysStocked then
			table.insert(guaranteed, seedId)
		elseif context.Wave >= rule.MinWave then
			table.insert(candidates, seedId)
		end
	end

	for _, seedId in guaranteed do
		table.insert(entries, rollEntry(seedId, SeedConfig.Seeds[seedId], rng, context))
	end

	local remainingSlots = math.max(0, SeedConfig.SlotCount - #entries)
	local function weightOf(seedId: string): number
		local rule = SeedConfig.Seeds[seedId]
		local crop = CropConfig.Get(seedId)
		local weight = rule.Weight
		if crop and table.find(SeedConfig.BoostedRarities, crop.Rarity) then
			weight *= 1 + SeedConfig.RarityBoostPerContinue * context.ContinueLevel
		end
		return weight
	end
	for _, seedId in WeightedRandom.PickManyUnique(candidates, remainingSlots, weightOf, rng) do
		table.insert(entries, rollEntry(seedId, SeedConfig.Seeds[seedId], rng, context))
	end

	table.sort(entries, function(a, b)
		local ca, cb = CropConfig.Get(a.SeedId), CropConfig.Get(b.SeedId)
		return (ca and ca.SortOrder or 0) < (cb and cb.SortOrder or 0)
	end)
	return entries
end

function SeedShop.new()
	return setmetatable({
		Version = 0,
		RestockedAt = 0,
		Entries = {} :: { Entry },
		_bySeed = {} :: { [string]: Entry },
		_purchases = {} :: { [number]: { [string]: number } },
	}, SeedShop)
end

function SeedShop:Restock(rng: Random, context: Context)
	self.Version += 1
	self.RestockedAt = Clock.Now()
	self.Entries = SeedShop.GenerateStock(rng, context)
	self._bySeed = {}
	for _, entry in self.Entries do
		self._bySeed[entry.SeedId] = entry
	end
	self._purchases = {}
end

function SeedShop:GetPurchased(userId: number, seedId: string): number
	local perPlayer = self._purchases[userId]
	return perPlayer and perPlayer[seedId] or 0
end

function SeedShop:CheckPurchase(userId: number, seedId: string, version: number): (boolean, string, Entry?)
	if version ~= self.Version then
		return false, ResultCode.StockChanged, nil
	end
	local entry = self._bySeed[seedId]
	if entry == nil then
		return false, ResultCode.NotFound, nil
	end
	if entry.Quantity <= 0 then
		return false, ResultCode.OutOfStock, nil
	end
	if entry.PerPlayerLimit and self:GetPurchased(userId, seedId) >= entry.PerPlayerLimit then
		return false, ResultCode.PurchaseLimit, nil
	end
	return true, ResultCode.Ok, entry
end

function SeedShop:CommitPurchase(userId: number, seedId: string)
	local entry = self._bySeed[seedId]
	assert(entry and entry.Quantity > 0, "[SeedShop] CommitPurchase without a valid CheckPurchase")
	entry.Quantity -= 1
	local perPlayer = self._purchases[userId]
	if perPlayer == nil then
		perPlayer = {}
		self._purchases[userId] = perPlayer
	end
	perPlayer[seedId] = (perPlayer[seedId] or 0) + 1
end

function SeedShop:Snapshot(userId: number, open: boolean)
	local entries = {}
	for _, entry in self.Entries do
		table.insert(entries, {
			SeedId = entry.SeedId,
			Quantity = entry.Quantity,
			Price = entry.Price,
			PerPlayerLimit = entry.PerPlayerLimit,
			Purchased = self:GetPurchased(userId, entry.SeedId),
		})
	end
	return { Version = self.Version, Open = open, Entries = entries, RestockedAt = self.RestockedAt }
end

return SeedShop
