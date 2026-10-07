--!strict
--[[
	UpgradeService
	Path: ServerScriptService.Server.Services.UpgradeService

	Permanent Candy-bought upgrades (profile.PermanentUpgrades), purchased in the lobby.
	Gameplay reads their effects through this service only:
		DeepPockets -> extra starting Match Coins
		GreenThumb  -> faster growth for crops the player plants

	Dependencies: EconomyConfig, ResultCode, Result; Registry: DataService, RemoteService

	API:
		UpgradeService:GetLevel(player, upgradeId) -> number
		UpgradeService:Purchase(player, upgradeId) -> Result
		UpgradeService:GetStartingCoinBonus(player) -> number
		UpgradeService:GetGrowthSpeedMultiplier(player) -> number
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local EconomyConfig = require(Shared.Config.EconomyConfig)
local Result = require(Shared.Utilities.Result)
local ResultCode = require(Shared.Constants.ResultCode)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)

local UpgradeService = {}

function UpgradeService:Init() end

function UpgradeService:Start()
	Services.RemoteService:OnInvoke("RequestPurchaseUpgrade", function(player: Player, upgradeId: string)
		return self:Purchase(player, upgradeId)
	end)
end

function UpgradeService:GetLevel(player: Player, upgradeId: string): number
	return Services.DataService:GetUpgradeLevel(player, upgradeId)
end

function UpgradeService:Purchase(player: Player, upgradeId: string)
	local definition = EconomyConfig.PermanentUpgrades[upgradeId]
	if definition == nil then
		return Result.Fail(ResultCode.NotFound)
	end
	if not Services.DataService:IsLoaded(player) then
		return Result.Fail(ResultCode.DataNotLoaded)
	end
	local ok, outcome = Services.DataService:Update(player, function(data)
		local level = data.PermanentUpgrades[upgradeId] or 0
		local cost = definition.Costs[level + 1]
		if cost == nil then
			return ResultCode.MaxLevel
		end
		if data.Candies < cost then
			return ResultCode.InsufficientFunds
		end
		data.Candies -= cost
		data.PermanentUpgrades[upgradeId] = level + 1
		return ResultCode.Ok
	end)
	if not ok then
		return Result.Fail(ResultCode.ServerError)
	end
	if outcome ~= ResultCode.Ok then
		return Result.Fail(outcome)
	end
	Services.DataService:RequestSave(player)
	return Result.Ok({ Level = self:GetLevel(player, upgradeId) })
end

function UpgradeService:GetStartingCoinBonus(player: Player): number
	return self:GetLevel(player, "DeepPockets") * EconomyConfig.PermanentUpgrades.DeepPockets.StartingCoinsPerLevel
end

function UpgradeService:GetGrowthSpeedMultiplier(player: Player): number
	return 1 + self:GetLevel(player, "GreenThumb") * EconomyConfig.PermanentUpgrades.GreenThumb.GrowthSpeedPerLevel
end

return UpgradeService
