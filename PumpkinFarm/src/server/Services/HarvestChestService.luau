--!strict
--[[
	HarvestChestService
	Path: ServerScriptService.Server.Services.HarvestChestService

	Owns each match's HarvestChest and its physical model (with a "View Harvest Chest"
	prompt that opens the HarvestUI on the client). Replicates contents (ChestUpdated)
	and the total (match attribute ChestValue) whenever something is deposited.

	Payout rule: the chest is the TEAM's haul. Every player who escapes receives the
	full chest value converted to Candies, multiplied by the Continue risk bonus. The
	chest is not emptied by an escape, so teammates who continue keep building it.

	Dependencies: HarvestChest, EconomyConfig, Attributes, ModelFactory

	API:
		HarvestChestService:InitMatch(match) / CleanupMatch(match)
		HarvestChestService:CanDeposit(match, itemId, quantity) -> boolean
		HarvestChestService:Deposit(match, itemId, displayName, icon, quantity, unitValue, force?) -> boolean
		HarvestChestService:GetTotalValue(match) -> number
		HarvestChestService:GetRiskBonus(match) -> number
		HarvestChestService:ComputePayout(match) -> number
		HarvestChestService:Forfeit(match)
		HarvestChestService:GetSnapshot(match) -> ChestSnapshot?
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local EconomyConfig = require(Shared.Config.EconomyConfig)

local Server = script:FindFirstAncestor("Server") :: Instance
local HarvestChest = require(Server.Classes.HarvestChest)
local ModelFactory = require(Server.Systems.ModelFactory)

local HarvestChestService = {}

local states: { [any]: { Chest: any, Model: Model } } = {}

function HarvestChestService:Init() end

function HarvestChestService:InitMatch(match: any)
	local model = ModelFactory.CreateChest()
	model:PivotTo(match.Arena.ChestCFrame)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ChestPrompt"
	prompt.ActionText = "View Harvest Chest"
	prompt.ObjectText = "Harvest Chest"
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 12
	prompt.HoldDuration = 0
	prompt:SetAttribute("OpensUI", "HarvestUI")
	prompt.Parent = model.PrimaryPart
	model.Parent = match.Folder
	states[match] = { Chest = HarvestChest.new(EconomyConfig.Chest), Model = model }
	match:SetAttribute(Attributes.ChestValue, 0)
end

function HarvestChestService:CleanupMatch(match: any)
	local state = states[match]
	if state then
		state.Model:Destroy()
		states[match] = nil
	end
end

function HarvestChestService:GetRiskBonus(match: any): number
	return EconomyConfig.Candies.RiskBonusPerContinue * match.ContinueLevel
end

function HarvestChestService:GetSnapshot(match: any): any
	local state = states[match]
	if state == nil then
		return nil
	end
	local chest = state.Chest
	return {
		Entries = chest:GetEntries(),
		TotalValue = chest:GetTotalValue(),
		EstimatedCandies = self:ComputePayout(match),
		RiskBonus = self:GetRiskBonus(match),
		Locked = chest:IsForfeited(),
		Capacity = chest:GetCapacity(),
	}
end

function HarvestChestService:_broadcast(match: any)
	local snapshot = self:GetSnapshot(match)
	if snapshot then
		match:SetAttribute(Attributes.ChestValue, snapshot.TotalValue)
		match:FireAll("ChestUpdated", snapshot)
	end
end

function HarvestChestService:CanDeposit(match: any, itemId: string, quantity: number): boolean
	local state = states[match]
	return state ~= nil and state.Chest:CanDeposit(itemId, quantity)
end

function HarvestChestService:Deposit(match: any, itemId: string, displayName: string, icon: string, quantity: number, unitValue: number, force: boolean?): boolean
	local state = states[match]
	if state == nil then
		return false
	end
	local ok = state.Chest:Deposit(itemId, displayName, icon, quantity, unitValue, force)
	if ok then
		self:_broadcast(match)
	end
	return ok
end

function HarvestChestService:GetTotalValue(match: any): number
	local state = states[match]
	return if state then state.Chest:GetTotalValue() else 0
end

function HarvestChestService:ComputePayout(match: any): number
	local state = states[match]
	if state == nil then
		return 0
	end
	return state.Chest:ComputePayout(EconomyConfig.Candies.ConversionRate, self:GetRiskBonus(match))
end

function HarvestChestService:Forfeit(match: any)
	local state = states[match]
	if state then
		state.Chest:Forfeit()
		self:_broadcast(match)
	end
end

return HarvestChestService
