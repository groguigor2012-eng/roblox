--!strict
--[[
	HarvestChest
	Path: ServerScriptService.Server.Classes.HarvestChest

	The match's secure, server-owned harvest ledger. Players can only add to it through
	validated server paths (harvests, boss kills, recovered crops); nobody can withdraw.
	Its value converts into permanent Candies only on extraction.

	Capacity: at most MaxItems units in total and MaxStacks distinct items. CanDeposit
	lets callers check BEFORE they consume what they are depositing (a harvested
	crop), so a full chest never destroys anything. `force` deposits ignore capacity
	(boss rewards).

	Pure data class (no Instances) so it is unit-tested directly.

	Dependencies: none

	API:
		HarvestChest.new(capacity?: { MaxItems: number, MaxStacks: number }) -> HarvestChest
		chest:CanDeposit(itemId, quantity) -> boolean
		chest:Deposit(itemId, displayName, icon, quantity, unitValue, force?) -> boolean
		chest:GetItemCount() -> number
		chest:GetCapacity() -> { Items, MaxItems, Stacks, MaxStacks }
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

export type Capacity = { MaxItems: number, MaxStacks: number }

function HarvestChest.new(capacity: Capacity?)
	return setmetatable({
		_entries = {} :: { [string]: ChestEntry },
		_forfeited = false,
		_capacity = capacity or { MaxItems = math.huge, MaxStacks = math.huge },
		_items = 0,
		_stacks = 0,
	}, HarvestChest)
end

function HarvestChest:CanDeposit(itemId: string, quantity: number): boolean
	if self._forfeited then
		return false
	end
	if self._items + quantity > self._capacity.MaxItems then
		return false
	end
	if self._entries[itemId] == nil and self._stacks >= self._capacity.MaxStacks then
		return false
	end
	return true
end

function HarvestChest:Deposit(itemId: string, displayName: string, icon: string, quantity: number, unitValue: number, force: boolean?): boolean
	if self._forfeited then
		return false
	end
	if type(quantity) ~= "number" or quantity <= 0 or quantity % 1 ~= 0 then
		return false
	end
	if type(unitValue) ~= "number" or unitValue < 0 or unitValue ~= unitValue then
		return false
	end
	if not force and not self:CanDeposit(itemId, quantity) then
		return false
	end
	local entry = self._entries[itemId]
	if entry == nil then
		entry = { ItemId = itemId, DisplayName = displayName, Icon = icon, Quantity = 0, UnitValue = unitValue, Value = 0 }
		self._entries[itemId] = entry
		self._stacks += 1
	end
	self._items += quantity
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

function HarvestChest:GetItemCount(): number
	return self._items
end

function HarvestChest:GetCapacity(): { Items: number, MaxItems: number, Stacks: number, MaxStacks: number }
	return {
		Items = self._items,
		MaxItems = self._capacity.MaxItems,
		Stacks = self._stacks,
		MaxStacks = self._capacity.MaxStacks,
	}
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
	self._items = 0
	self._stacks = 0
end

function HarvestChest:IsForfeited(): boolean
	return self._forfeited
end

return HarvestChest
