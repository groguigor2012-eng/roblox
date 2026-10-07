--!strict
--[[
	SeedShopService
	Path: ServerScriptService.Server.Services.SeedShopService

	Runs the randomized Seed Shop of every match. Stock is rolled on the server from
	SeedConfig with the match's seeded Random at each Intermission and each
	ContinuePreparation, then broadcast (ShopUpdated). Purchase flow:

		client RequestBuySeed(seedId, stockVersion)
		-> session/match/profile validation -> shop open in this state
		-> stock + version + per-player limit check (SeedShop:CheckPurchase)
		-> Candies check and charge + seed grant in ONE profile mutation
		-> stock decrement (SeedShop:CommitPurchase)
		-> response + ShopUpdated broadcast to the match

	Nothing between the stock check and the decrement yields, so two simultaneous
	requests for the last seed can never both succeed.

	Dependencies: SeedShop, Result, ResultCode; Registry: PlayerService, DataService,
	              RemoteService

	API:
		SeedShopService:InitMatch(match) / CleanupMatch(match)
		SeedShopService:Restock(match)
		SeedShopService:SetOpen(match, open)
		SeedShopService:IsOpen(match) -> boolean
		SeedShopService:Purchase(player, seedId, version) -> Result
		SeedShopService:GetSnapshot(match, player) -> ShopSnapshot?
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Result = require(Shared.Utilities.Result)
local ResultCode = require(Shared.Constants.ResultCode)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local SeedShop = require(Server.Classes.SeedShop)

local SeedShopService = {}

local states: { [any]: { Shop: any, Open: boolean } } = {}

function SeedShopService:Init() end

function SeedShopService:Start()
	Services.RemoteService:OnInvoke("RequestBuySeed", function(player: Player, seedId: string, version: number)
		return self:Purchase(player, seedId, version)
	end)
end

function SeedShopService:InitMatch(match: any)
	states[match] = { Shop = SeedShop.new(), Open = false }
end

function SeedShopService:CleanupMatch(match: any)
	states[match] = nil
end

function SeedShopService:GetSnapshot(match: any, player: Player): any
	local state = states[match]
	if state == nil then
		return nil
	end
	return state.Shop:Snapshot(player.UserId, state.Open)
end

function SeedShopService:_broadcast(match: any)
	for _, player in match:GetPlayers() do
		Services.RemoteService:FireClient("ShopUpdated", player, self:GetSnapshot(match, player))
	end
end

function SeedShopService:Restock(match: any)
	local state = states[match]
	if state == nil then
		return
	end
	local context = match:GetContext()
	-- Seeds unlock by completed waves (MinWave), so use the raw wave count here.
	context.Wave = match.Wave
	state.Shop:Restock(match.Rng, context)
	self:_broadcast(match)
	match:FireAll("MatchEvent", "ShopRestocked", { Version = state.Shop.Version })
end

function SeedShopService:SetOpen(match: any, open: boolean)
	local state = states[match]
	if state == nil or state.Open == open then
		return
	end
	state.Open = open
	self:_broadcast(match)
end

function SeedShopService:IsOpen(match: any): boolean
	local state = states[match]
	return state ~= nil and state.Open
end

function SeedShopService:Purchase(player: Player, seedId: string, version: number)
	local session = Services.PlayerService:GetSession(player)
	local match = session and session.Match
	if match == nil then
		return Result.Fail(ResultCode.NotInMatch)
	end
	local state = states[match]
	if state == nil then
		return Result.Fail(ResultCode.NotInMatch)
	end
	if not Services.DataService:IsLoaded(player) then
		return Result.Fail(ResultCode.DataNotLoaded)
	end
	if not state.Open then
		return Result.Fail(ResultCode.InvalidState)
	end

	local ok, code, entry = state.Shop:CheckPurchase(player.UserId, seedId, version)
	if not ok or entry == nil then
		return Result.Fail(code)
	end

	local price = entry.Price
	local mutated, paid = Services.DataService:Update(player, function(data)
		if data.Candies < price then
			return false
		end
		data.Candies -= price
		data.Seeds[seedId] = (data.Seeds[seedId] or 0) + 1
		return true
	end)
	if not mutated then
		return Result.Fail(ResultCode.ServerError)
	end
	if not paid then
		return Result.Fail(ResultCode.InsufficientFunds)
	end

	state.Shop:CommitPurchase(player.UserId, seedId)
	self:_broadcast(match)
	return Result.Ok({ SeedId = seedId, Remaining = entry.Quantity })
end

return SeedShopService
