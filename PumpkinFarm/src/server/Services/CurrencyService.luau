--!strict
--[[
	CurrencyService
	Path: ServerScriptService.Server.Services.CurrencyService

	Uniform entry point for both currencies so purchase and reward code does not care
	which one a price or reward is in. Routes MatchCoins to MatchCoinService and
	Candies to CandyService (which enforce validation and persistence rules).

	Dependencies: CurrencyId; Registry: MatchCoinService, CandyService

	API:
		CurrencyService:Get(player, currencyId) -> number
		CurrencyService:CanAfford(player, currencyId, amount) -> boolean
		CurrencyService:TrySpend(player, currencyId, amount, reason) -> boolean
		CurrencyService:Grant(player, currencyId, amount, reason) -> boolean
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local CurrencyId = require(Shared.Constants.CurrencyId)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)

local CurrencyService = {}

local function backend(currencyId: string): any
	if currencyId == CurrencyId.MatchCoins then
		return Services.MatchCoinService
	elseif currencyId == CurrencyId.Candies then
		return Services.CandyService
	end
	error(`[CurrencyService] unknown currency {currencyId}`)
end

function CurrencyService:Init() end

function CurrencyService:Get(player: Player, currencyId: string): number
	return backend(currencyId):Get(player)
end

function CurrencyService:CanAfford(player: Player, currencyId: string, amount: number): boolean
	return backend(currencyId):CanAfford(player, amount)
end

function CurrencyService:TrySpend(player: Player, currencyId: string, amount: number, reason: string): boolean
	return backend(currencyId):TrySpend(player, amount, reason)
end

function CurrencyService:Grant(player: Player, currencyId: string, amount: number, reason: string): boolean
	local result = backend(currencyId):Add(player, amount, reason)
	-- MatchCoinService returns the amount added, CandyService a boolean.
	return if type(result) == "number" then result > 0 else result == true
end

return CurrencyService
