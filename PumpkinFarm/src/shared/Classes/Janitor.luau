--!strict
--[[
	Janitor
	Path: ReplicatedStorage.Shared.Classes.Janitor

	Tracks everything a system creates (connections, instances, threads, callbacks and
	objects with a Destroy/Disconnect method) and releases it in reverse order of
	registration. Every match, enemy, crop, defense, controller and character session
	owns exactly one Janitor, so tearing an owner down can never leak a connection.

	Dependencies: none.

	API:
		Janitor.new() -> Janitor
		Janitor:Add(task, methodName?) -> task       -- methodName overrides the cleanup method
		Janitor:AddKeyed(key, task, methodName?) -> task  -- replaces (and cleans) a previous task with the same key
		Janitor:Remove(key)                          -- cleans one keyed task now
		Janitor:Detach(key) -> task?                 -- stops tracking a keyed task WITHOUT cleaning it
		Janitor:Connect(signal, handler) -> connection
		Janitor:Cleanup()                            -- cleans everything, Janitor stays usable
		Janitor:Destroy()                            -- cleans everything, later Adds are cleaned immediately
		Janitor:IsDestroyed() -> boolean
]]

type TaskRecord = {
	Task: any,
	Method: string?,
}

local Janitor = {}
Janitor.__index = Janitor

export type Janitor = typeof(setmetatable(
	{} :: {
		_tasks: { TaskRecord },
		_keyed: { [any]: TaskRecord },
		_destroyed: boolean,
		_cleaning: boolean,
	},
	Janitor
))

local function cleanTask(record: TaskRecord)
	local item = record.Task
	local method = record.Method
	local kind = typeof(item)

	if method ~= nil then
		local fn = (item :: any)[method]
		if type(fn) == "function" then
			fn(item)
		end
		return
	end

	if kind == "RBXScriptConnection" then
		(item :: RBXScriptConnection):Disconnect()
	elseif kind == "Instance" then
		(item :: Instance):Destroy()
	elseif kind == "function" then
		(item :: () -> ())()
	elseif kind == "thread" then
		local thread = item :: thread
		if coroutine.status(thread) ~= "dead" and thread ~= coroutine.running() then
			pcall(task.cancel, thread)
		end
	elseif kind == "table" then
		local tbl = item :: any
		if type(tbl.Destroy) == "function" then
			tbl:Destroy()
		elseif type(tbl.Disconnect) == "function" then
			tbl:Disconnect()
		end
	end
end

local function safeClean(record: TaskRecord)
	local ok, err = pcall(cleanTask, record)
	if not ok then
		warn(`[Janitor] cleanup task failed: {err}`)
	end
end

function Janitor.new(): Janitor
	return setmetatable({
		_tasks = {},
		_keyed = {},
		_destroyed = false,
		_cleaning = false,
	}, Janitor)
end

function Janitor.Add<T>(self: Janitor, item: T, methodName: string?): T
	local record: TaskRecord = { Task = item, Method = methodName }
	if self._destroyed then
		-- Anything registered after destruction is released immediately so late async
		-- work (e.g. a model created after its owner died) can never leak.
		safeClean(record)
		return item
	end
	table.insert(self._tasks, record)
	return item
end

function Janitor.AddKeyed<T>(self: Janitor, key: any, item: T, methodName: string?): T
	self:Remove(key)
	local record: TaskRecord = { Task = item, Method = methodName }
	if self._destroyed then
		safeClean(record)
		return item
	end
	self._keyed[key] = record
	return item
end

function Janitor.Remove(self: Janitor, key: any)
	local record = self._keyed[key]
	if record then
		self._keyed[key] = nil
		safeClean(record)
	end
end

-- Hands ownership of a keyed task back to the caller (e.g. a corpse that must
-- outlive its enemy object for a moment).
function Janitor.Detach(self: Janitor, key: any): any
	local record = self._keyed[key]
	if record then
		self._keyed[key] = nil
		return record.Task
	end
	return nil
end

function Janitor.Connect(self: Janitor, signal: any, handler: (...any) -> ()): any
	local connection = signal:Connect(handler)
	self:Add(connection)
	return connection
end

function Janitor.Cleanup(self: Janitor)
	if self._cleaning then
		return
	end
	self._cleaning = true

	for key, record in self._keyed do
		self._keyed[key] = nil
		safeClean(record)
	end

	-- Tasks added while cleaning are appended and picked up by the loop.
	local tasks = self._tasks
	while #tasks > 0 do
		local record = table.remove(tasks) :: TaskRecord
		safeClean(record)
	end

	self._cleaning = false
end

function Janitor.Destroy(self: Janitor)
	self._destroyed = true
	self:Cleanup()
end

function Janitor.IsDestroyed(self: Janitor): boolean
	return self._destroyed
end

return Janitor
