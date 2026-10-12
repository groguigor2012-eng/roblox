--!strict
-- Authoritative registry of claimable world objects (eggs, item pickups). Each record has a
-- server-generated id and a state. `tryClaim` is a single check-and-set with no yields, so
-- when two players trigger the same object in the same frame exactly one of them wins and
-- every later request sees the record as gone.

export type State = "Active" | "Claimed" | "Expired"

export type Record = {
	id: string,
	kind: string, -- egg tier or item id
	zoneId: string,
	position: Vector3,
	spawnedAt: number,
	expiresAt: number,
	state: State,
	model: Model?,
	claimedBy: number?,
	hidden: boolean?,
	isDrop: boolean?, -- item pickups created by a world drop rather than a zone timer
}

local ClaimRegistry = {}
ClaimRegistry.__index = ClaimRegistry

export type ClaimRegistry = typeof(setmetatable({} :: { _records: { [string]: Record }, _count: number }, ClaimRegistry))

function ClaimRegistry.new(): ClaimRegistry
	return setmetatable({ _records = {}, _count = 0 }, ClaimRegistry)
end

function ClaimRegistry.add(self: ClaimRegistry, record: Record)
	assert(self._records[record.id] == nil, "duplicate claim registry id")
	self._records[record.id] = record
	self._count += 1
end

-- Only Active records are returned; claimed/expired ones are already invalid.
function ClaimRegistry.getActive(self: ClaimRegistry, id: string): Record?
	local record = self._records[id]
	if record and record.state == "Active" then
		return record
	end
	return nil
end

function ClaimRegistry.tryClaim(self: ClaimRegistry, id: string, userId: number): Record?
	local record = self._records[id]
	if not record or record.state ~= "Active" then
		return nil
	end
	record.state = "Claimed"
	record.claimedBy = userId
	return record
end

-- Returns a claimed record to Active (used only when a claim is rolled back before any reward
-- was granted).
function ClaimRegistry.release(self: ClaimRegistry, id: string)
	local record = self._records[id]
	if record and record.state == "Claimed" then
		record.state = "Active"
		record.claimedBy = nil
	end
end

-- Removes a record entirely (after it was claimed or expired) and destroys its model.
function ClaimRegistry.remove(self: ClaimRegistry, id: string, finalState: State): Record?
	local record = self._records[id]
	if not record then
		return nil
	end
	record.state = finalState
	self._records[id] = nil
	self._count -= 1
	if record.model then
		record.model:Destroy()
		record.model = nil
	end
	return record
end

function ClaimRegistry.count(self: ClaimRegistry): number
	return self._count
end

function ClaimRegistry.countWhere(self: ClaimRegistry, predicate: (Record) -> boolean): number
	local n = 0
	for _, record in self._records do
		if record.state == "Active" and predicate(record) then
			n += 1
		end
	end
	return n
end

function ClaimRegistry.active(self: ClaimRegistry): { Record }
	local list = {}
	for _, record in self._records do
		if record.state == "Active" then
			table.insert(list, record)
		end
	end
	return list
end

function ClaimRegistry.positions(self: ClaimRegistry): { Vector3 }
	local list = {}
	for _, record in self._records do
		table.insert(list, record.position)
	end
	return list
end

-- Ids whose lifetime has passed.
function ClaimRegistry.expired(self: ClaimRegistry, now: number): { string }
	local ids = {}
	for id, record in self._records do
		if record.state == "Active" and now >= record.expiresAt then
			table.insert(ids, id)
		end
	end
	return ids
end

return ClaimRegistry
