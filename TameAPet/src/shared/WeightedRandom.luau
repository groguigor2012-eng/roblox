--!strict
-- Weighted random selection over { [key]: weight } tables.
-- Entries are iterated in sorted key order so a given Random seed always produces the same
-- result regardless of hash-table ordering. Non-positive or non-finite weights are ignored.

export type Pool = { [string]: number }

local WeightedRandom = {}

local function isValidWeight(weight: any): boolean
	return type(weight) == "number" and weight == weight and weight > 0 and weight < math.huge
end

function WeightedRandom.entries(pool: Pool): ({ { key: string, weight: number } }, number)
	local entries = {}
	local total = 0
	for key, weight in pool do
		if isValidWeight(weight) then
			table.insert(entries, { key = key, weight = weight })
			total += weight
		end
	end
	table.sort(entries, function(a, b)
		return a.key < b.key
	end)
	return entries, total
end

function WeightedRandom.total(pool: Pool): number
	local _, total = WeightedRandom.entries(pool)
	return total
end

-- `roll01` lets tests inject a value in [0, 1); production passes a Random.
function WeightedRandom.pickWithRoll(pool: Pool, roll01: number): string?
	local entries, total = WeightedRandom.entries(pool)
	if total <= 0 then
		return nil
	end
	local target = math.clamp(roll01, 0, 1) * total
	local accumulated = 0
	for _, entry in entries do
		accumulated += entry.weight
		if target < accumulated then
			return entry.key
		end
	end
	return entries[#entries].key
end

function WeightedRandom.pick(pool: Pool, rng: Random): string?
	return WeightedRandom.pickWithRoll(pool, rng:NextNumber())
end

-- Copy of `pool` keeping only keys for which `keep(key)` is true.
function WeightedRandom.filter(pool: Pool, keep: (string) -> boolean): Pool
	local result: Pool = {}
	for key, weight in pool do
		if isValidWeight(weight) and keep(key) then
			result[key] = weight
		end
	end
	return result
end

return WeightedRandom
