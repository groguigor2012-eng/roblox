--!strict
--[[
	WeightedRandom
	Path: ReplicatedStorage.Shared.Utilities.WeightedRandom

	Deterministic weighted selection driven by an explicit Random object, so the seed
	shop and wave composer produce reproducible results from a match seed (useful for
	tests and for replaying bug reports).

	Dependencies: none.

	API:
		Pick(items, weightOf, rng) -> item?                    -- nil when total weight <= 0
		PickManyUnique(items, count, weightOf, rng) -> { item } -- weighted, without replacement
]]

local WeightedRandom = {}

function WeightedRandom.Pick<T>(items: { T }, weightOf: (T) -> number, rng: Random): T?
	local total = 0
	for _, item in items do
		total += math.max(0, weightOf(item))
	end
	if total <= 0 then
		return nil
	end

	local roll = rng:NextNumber() * total
	local cumulative = 0
	for _, item in items do
		cumulative += math.max(0, weightOf(item))
		if roll < cumulative then
			return item
		end
	end
	-- Floating point guard: the roll can equal the total when NextNumber returns ~1.
	for index = #items, 1, -1 do
		if weightOf(items[index]) > 0 then
			return items[index]
		end
	end
	return nil
end

function WeightedRandom.PickManyUnique<T>(items: { T }, count: number, weightOf: (T) -> number, rng: Random): { T }
	local pool = table.clone(items)
	local picked = {}
	while #picked < count and #pool > 0 do
		local choice = WeightedRandom.Pick(pool, weightOf, rng)
		if choice == nil then
			break
		end
		table.insert(picked, choice)
		local index = table.find(pool, choice)
		if index then
			table.remove(pool, index)
		end
	end
	return picked
end

return WeightedRandom
