--!strict
--[[
	Signal
	Path: ReplicatedStorage.Shared.Classes.Signal

	Lightweight in-process event. Unlike BindableEvent it passes tables by reference
	(enemy objects, match objects) and fires synchronously, so a handler that removes an
	enemy from a registry runs before the code that fired the signal continues.
	Handler errors are caught and reported so one faulty listener cannot break others.

	Dependencies: none.

	API:
		Signal.new() -> Signal
		Signal:Connect(handler) -> Connection { Connected: boolean, Disconnect() }
		Signal:Once(handler) -> Connection
		Signal:Fire(...)
		Signal:Wait() -> ...            (yields the calling thread)
		Signal:DisconnectAll()
		Signal:Destroy()
]]

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
	_handler: (...any) -> (),
	_signal: any,
}

local Connection = {}
Connection.__index = Connection

function Connection.Disconnect(self: Connection)
	if not self.Connected then
		return
	end
	self.Connected = false
	local handlers = self._signal._connections
	local index = table.find(handlers, self)
	if index then
		table.remove(handlers, index)
	end
end

local Signal = {}
Signal.__index = Signal

export type Signal = typeof(setmetatable(
	{} :: {
		_connections: { Connection },
		_destroyed: boolean,
	},
	Signal
))

function Signal.new(): Signal
	return setmetatable({
		_connections = {},
		_destroyed = false,
	}, Signal)
end

function Signal.Connect(self: Signal, handler: (...any) -> ()): Connection
	local connection = setmetatable({
		Connected = not self._destroyed,
		_handler = handler,
		_signal = self,
	}, Connection) :: any
	if not self._destroyed then
		table.insert(self._connections, connection)
	end
	return connection
end

function Signal.Once(self: Signal, handler: (...any) -> ()): Connection
	local connection: Connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end

function Signal.Fire(self: Signal, ...: any)
	if self._destroyed then
		return
	end
	-- Snapshot so handlers may disconnect themselves (or others) while firing.
	local snapshot = table.clone(self._connections)
	for _, connection in snapshot do
		if connection.Connected then
			local ok, err = xpcall(connection._handler, debug.traceback, ...)
			if not ok then
				warn(`[Signal] handler error: {err}`)
			end
		end
	end
end

function Signal.Wait(self: Signal): ...any
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal.DisconnectAll(self: Signal)
	for _, connection in self._connections do
		connection.Connected = false
	end
	table.clear(self._connections)
end

function Signal.Destroy(self: Signal)
	self:DisconnectAll()
	self._destroyed = true
end

return Signal
