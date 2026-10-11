--!strict
-- In-memory stand-in for a GlobalDataStore. Used by the headless tests and,
-- only in Studio when DataConfig.UseMemoryStoreInStudio is on, when real
-- DataStores are unreachable. Values are deep-copied on every read and write
-- to mimic serialisation, and failures can be queued to test retry paths.

local MemoryDataStore = {}
MemoryDataStore.__index = MemoryDataStore

type Failure = { Message: string, AfterCommit: boolean }

type Fields = {
	_data: { [string]: any },
	_failures: { Failure },
	UpdateCalls: number,
}

export type MemoryDataStore = typeof(setmetatable({} :: Fields, MemoryDataStore))

local function copyValue(value: any, depth: number): any
	if depth > 32 then
		error("104: Cannot store value: nested too deeply", 0)
	end
	local kind = type(value)
	if kind == "table" then
		local result = {}
		for key, entry in value do
			if type(key) ~= "string" and type(key) ~= "number" then
				error(`104: Cannot store table with {type(key)} key`, 0)
			end
			result[key] = copyValue(entry, depth + 1)
		end
		return result
	elseif kind == "nil" or kind == "string" or kind == "number" or kind == "boolean" then
		return value
	end
	error(`104: Cannot store {typeof(value)} in data store`, 0)
end

function MemoryDataStore.new(): MemoryDataStore
	local self: Fields = { _data = {}, _failures = {}, UpdateCalls = 0 }
	return setmetatable(self, MemoryDataStore)
end

-- Makes the next call(s) throw these messages, in order. With afterCommit,
-- the write is stored first and the call still throws (a lost response).
function MemoryDataStore.QueueFailure(self: MemoryDataStore, message: string, afterCommit: boolean?)
	table.insert(self._failures, { Message = message, AfterCommit = afterCommit == true })
end

function MemoryDataStore.SetRaw(self: MemoryDataStore, key: string, value: any)
	self._data[key] = copyValue(value, 0)
end

function MemoryDataStore.GetRaw(self: MemoryDataStore, key: string): any
	return copyValue(self._data[key], 0)
end

-- Throws the next queued failure whose timing matches.
local function takeFailure(self: MemoryDataStore, afterCommit: boolean)
	local failure = self._failures[1]
	if failure and failure.AfterCommit == afterCommit then
		table.remove(self._failures, 1)
		error(failure.Message, 0)
	end
end

function MemoryDataStore.GetAsync(self: MemoryDataStore, key: string): any
	takeFailure(self, false)
	return copyValue(self._data[key], 0)
end

-- Mirrors GlobalDataStore:UpdateAsync: returning nil from the transform
-- cancels the write (and this returns nil).
function MemoryDataStore.UpdateAsync(
	self: MemoryDataStore,
	key: string,
	transform: (stored: any, keyInfo: any) -> (any, { number }?)
): any
	self.UpdateCalls += 1
	takeFailure(self, false)
	local newValue = transform(copyValue(self._data[key], 0), nil)
	if newValue == nil then
		return nil
	end
	self._data[key] = copyValue(newValue, 0)
	takeFailure(self, true)
	return copyValue(newValue, 0)
end

return MemoryDataStore
