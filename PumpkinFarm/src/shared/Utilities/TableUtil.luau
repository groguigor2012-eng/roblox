--!strict
--[[
	TableUtil
	Path: ReplicatedStorage.Shared.Utilities.TableUtil

	Table helpers shared by configs (deep freezing), the data layer (deep copy +
	template reconciliation) and gameplay (counting, shuffling).

	Dependencies: none.

	API:
		DeepCopy(value) -> value
		DeepFreeze(table) -> table          -- freezes nested tables, returns the same table
		Reconcile(target, template) -> number  -- fills missing keys from template, returns keys added
		Count(table) -> number
		Keys(table) -> { key }               -- sorted when keys are strings or numbers
		Shuffle(array, rng) -> array         -- in-place Fisher-Yates
		Sum(array, selector?) -> number
]]

local TableUtil = {}

function TableUtil.DeepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value :: any do
		copy[TableUtil.DeepCopy(key)] = TableUtil.DeepCopy(item)
	end
	return copy :: any
end

function TableUtil.DeepFreeze<T>(value: T): T
	if type(value) ~= "table" or table.isfrozen(value :: any) then
		return value
	end
	for _, item in value :: any do
		if type(item) == "table" then
			TableUtil.DeepFreeze(item)
		end
	end
	table.freeze(value :: any)
	return value
end

-- Adds keys present in `template` but missing from `target`. Existing values are never
-- overwritten, even when their type differs: overwriting would destroy player data, so
-- schema changes must go through Migrations instead.
function TableUtil.Reconcile(target: { [any]: any }, template: { [any]: any }): number
	local added = 0
	for key, templateValue in template do
		local current = target[key]
		if current == nil then
			target[key] = TableUtil.DeepCopy(templateValue)
			added += 1
		elseif type(current) == "table" and type(templateValue) == "table" then
			added += TableUtil.Reconcile(current, templateValue)
		end
	end
	return added
end

function TableUtil.Count(tbl: { [any]: any }): number
	local count = 0
	for _ in tbl do
		count += 1
	end
	return count
end

function TableUtil.Keys<K>(tbl: { [K]: any }): { K }
	local keys = {}
	for key in tbl do
		table.insert(keys, key)
	end
	table.sort(keys, function(a: any, b: any)
		local ta, tb = type(a), type(b)
		if ta ~= tb then
			return ta < tb
		end
		if ta == "string" or ta == "number" then
			return a < b
		end
		return tostring(a) < tostring(b)
	end)
	return keys
end

function TableUtil.Shuffle<T>(array: { T }, rng: Random): { T }
	for i = #array, 2, -1 do
		local j = rng:NextInteger(1, i)
		array[i], array[j] = array[j], array[i]
	end
	return array
end

function TableUtil.Sum<T>(array: { T }, selector: ((T) -> number)?): number
	local total = 0
	for _, item in array do
		total += if selector then selector(item) else (item :: any)
	end
	return total
end

return TableUtil
