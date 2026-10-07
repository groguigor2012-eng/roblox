--!strict
--[[
	HarvestChest
	Path: ServerScriptService.Server.Classes.HarvestChest

	The match's secure, server-owned harvest ledger. Players can only add to it through
	validated server paths (harvests, boss kills, recovered crops); nobody can withdraw.
	Its value converts into permanent Candies only on extraction.

	Pure data class (no Instances) so it is unit-tested directly.

	Dependencies: none

	API:
		HarvestChest.new() -> HarvestChest
		chest:Deposit(itemId, displayName, icon, quantity, unitValue) -> boolean
		chest:GetTotalValue() -> number
		chest:GetEntries() -> { ChestEntry }     (sorted by value, descending)
		chest:ComputePayout(conversionRate, riskBonus) -> number
		chest:Forfeit()                           -- match lost: contents are gone
		chest:IsForfeited() -> boolean
]]

export type ChestEntry = {
	ItemId: string,
	DisplayName: string,
	Icon: string,
	Quantity: number,
	UnitValue: number,
	Value: number,
}

local HarvestChest = {}
HarvestChest.__index = HarvestChest

function HarvestChest.new()
	return setmetatable({
		_entries = {} :: { [string]: ChestEntry },
		_forfeited = false,
	}, HarvestChest)
end

function HarvestChest:Deposit(itemId: string, displayName: string, icon: string, quantity: number, unitValue: number): boolean
	if self._forfeited then
		return false
	end
	if type(quantity) ~= "number" or quantity <= 0 or quantity % 1 ~= 0 then
		return false
	end
	if type(unitValue) ~= "number" or unitValue < 0 or unitValue ~= unitValue then
		return false
	end
	local entry = self._entries[itemId]
	if entry == nil then
		entry = { ItemId = itemId, DisplayName = displayName, Icon = icon, Quantity = 0, UnitValue = unitValue, Value = 0 }
		self._entries[itemId] = entry
	end
	entry.Quantity += quantity
	entry.UnitValue = unitValue
	entry.Value += quantity * unitValue
	return true
end

function HarvestChest:GetTotalValue(): number
	local total = 0
	for _, entry in self._entries do
		total += entry.Value
	end
	return total
end

function HarvestChest:GetEntries(): { ChestEntry }
	local list = {}
	for _, entry in self._entries do
		table.insert(list, table.clone(entry))
	end
	table.sort(list, function(a, b)
		if a.Value == b.Value then
			return a.ItemId < b.ItemId
		end
		return a.Value > b.Value
	end)
	return list
end

function HarvestChest:ComputePayout(conversionRate: number, riskBonus: number): number
	if self._forfeited then
		return 0
	end
	return math.floor(self:GetTotalValue() * conversionRate * (1 + riskBonus))
end

function HarvestChest:Forfeit()
	self._forfeited = true
	table.clear(self._entries)
end

function HarvestChest:IsForfeited(): boolean
	return self._forfeited
end

return HarvestChest
