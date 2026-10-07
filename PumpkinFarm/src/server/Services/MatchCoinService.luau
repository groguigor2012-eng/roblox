--!strict
--[[
	MatchCoinService
	Path: ServerScriptService.Server.Services.MatchCoinService

	Temporary per-match currency. Balances live only in server memory, keyed by player,
	and are cleared when the player leaves the match (escape, defeat or disconnect), so
	Match Coins can never leak into another match or into persistence. The balance is
	mirrored to the Player "MatchCoins" attribute for the HUD (display only).

	Dependencies: EconomyConfig, Attributes

	API:
		MatchCoinService:Reset(player, startingAmount)
		MatchCoinService:Clear(player)
		MatchCoinService:Get(player) -> number
		MatchCoinService:Add(player, amount, reason) -> number   (amount actually added)
		MatchCoinService:TrySpend(player, amount, reason) -> boolean
		MatchCoinService:CanAfford(player, amount) -> boolean
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local EconomyConfig = require(Shared.Config.EconomyConfig)

local MatchCoinService = {}

local balances: { [Player]: number } = {}

local function valid(amount: number): boolean
	return type(amount) == "number" and amount == amount and amount > 0 and amount < math.huge
end

local function publish(player: Player)
	player:SetAttribute(Attributes.MatchCoins, balances[player])
end

function MatchCoinService:Init() end

function MatchCoinService:Reset(player: Player, startingAmount: number)
	balances[player] = math.max(0, math.floor(startingAmount))
	publish(player)
end

function MatchCoinService:Clear(player: Player)
	balances[player] = nil
	player:SetAttribute(Attributes.MatchCoins, nil)
end

function MatchCoinService:Get(player: Player): number
	return balances[player] or 0
end

function MatchCoinService:CanAfford(player: Player, amount: number): boolean
	return valid(amount) and balances[player] ~= nil and balances[player] >= amount
end

function MatchCoinService:Add(player: Player, amount: number, _reason: string): number
	local balance = balances[player]
	if balance == nil or not valid(amount) then
		return 0
	end
	local whole = math.floor(amount)
	local newBalance = math.min(EconomyConfig.MatchCoins.Max, balance + whole)
	balances[player] = newBalance
	publish(player)
	return newBalance - balance
end

function MatchCoinService:TrySpend(player: Player, amount: number, _reason: string): boolean
	if not self:CanAfford(player, amount) then
		return false
	end
	balances[player] -= math.floor(amount)
	publish(player)
	return true
end

return MatchCoinService
