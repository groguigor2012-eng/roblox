--!strict
-- Minimal synchronous signal. Handlers run in order; a handler that errors is reported
-- without stopping the others.

export type Connection = { Disconnect: (self: Connection) -> (), Connected: boolean }
export type Signal<T...> = {
	Connect: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
}

local Signal = {}
Signal.__index = Signal

function Signal.new<T...>(): Signal<T...>
	local self = setmetatable({ _handlers = {} :: { { handler: any, connection: any } } }, Signal)
	return (self :: any) :: Signal<T...>
end

function Signal:Connect(handler)
	local connection = { Connected = true }
	local handlers = self._handlers
	local entry = { handler = handler, connection = connection }
	table.insert(handlers, entry)
	function connection.Disconnect(conn)
		if not conn.Connected then
			return
		end
		conn.Connected = false
		local index = table.find(handlers, entry)
		if index then
			table.remove(handlers, index)
		end
	end
	return connection
end

function Signal:Once(handler)
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end

function Signal:Fire(...)
	-- Copy so handlers may disconnect while firing.
	local snapshot: { { handler: any, connection: any } } = table.clone(self._handlers)
	for _, entry in snapshot do
		if entry.connection.Connected then
			local ok, err = pcall(entry.handler, ...)
			if not ok then
				warn(`[Signal] handler error: {err}\n{debug.traceback()}`)
			end
		end
	end
end

function Signal:DisconnectAll()
	for _, entry in self._handlers do
		entry.connection.Connected = false
	end
	table.clear(self._handlers)
end

return Signal
