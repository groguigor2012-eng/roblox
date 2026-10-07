--[[
	Virtual-time task scheduler for the server simulation.

	Replaces the `task` library and `os.clock` inside simulated modules so minutes of
	game time run in a fraction of a second, deterministically. Semantics follow Roblox:
	task.spawn resumes immediately, task.defer/delay/wait resume on a later frame.
	Errors in resumed threads are recorded (like Roblox printing a script error) so a
	scenario can fail on them.
]]

local Scheduler = {}
Scheduler.__index = Scheduler

function Scheduler.new()
	local self = setmetatable({}, Scheduler)
	self.Now = 0
	self.Errors = {} :: { string }
	self._sleepers = {} :: { { Thread: thread, WakeAt: number, Args: { any }?, Started: number } }
	self._sequence = 0
	return self
end

function Scheduler:_resume(thread: thread, ...)
	if coroutine.status(thread) ~= "suspended" then
		return
	end
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		local message = tostring(err) .. "\n" .. debug.traceback(thread)
		table.insert(self.Errors, message)
	end
end

function Scheduler:_schedule(thread: thread, delay: number, args: { any }?)
	self._sequence += 1
	table.insert(self._sleepers, {
		Thread = thread,
		WakeAt = self.Now + math.max(0, delay),
		Args = args,
		Started = self.Now,
		Sequence = self._sequence,
	})
end

function Scheduler:Spawn(fnOrThread: any, ...)
	local thread = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
	self:_resume(thread, ...)
	return thread
end

function Scheduler:Defer(fnOrThread: any, ...)
	local thread = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
	self:_schedule(thread, 0, table.pack(...))
	return thread
end

function Scheduler:Delay(seconds: number, fnOrThread: any, ...)
	local thread = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
	self:_schedule(thread, seconds or 0, table.pack(...))
	return thread
end

function Scheduler:Wait(seconds: number?): number
	local thread = coroutine.running()
	local started = self.Now
	self:_schedule(thread, seconds or 0, nil)
	coroutine.yield()
	return self.Now - started
end

function Scheduler:Cancel(thread: thread)
	for index = #self._sleepers, 1, -1 do
		if self._sleepers[index].Thread == thread then
			table.remove(self._sleepers, index)
		end
	end
	if coroutine.status(thread) == "suspended" then
		coroutine.close(thread)
	end
end

-- Advances virtual time to `target`, waking sleepers in order.
function Scheduler:AdvanceTo(target: number)
	while true do
		local nextIndex, nextEntry = nil, nil
		for index, entry in self._sleepers do
			if entry.WakeAt <= target and (nextEntry == nil or entry.WakeAt < nextEntry.WakeAt or (entry.WakeAt == nextEntry.WakeAt and entry.Sequence < nextEntry.Sequence)) then
				nextIndex, nextEntry = index, entry
			end
		end
		if nextEntry == nil then
			break
		end
		table.remove(self._sleepers, nextIndex)
		self.Now = math.max(self.Now, nextEntry.WakeAt)
		if nextEntry.Args then
			self:_resume(nextEntry.Thread, table.unpack(nextEntry.Args, 1, nextEntry.Args.n))
		else
			self:_resume(nextEntry.Thread, self.Now - nextEntry.Started)
		end
	end
	self.Now = target
end

-- The `task` library exposed to simulated modules.
function Scheduler:CreateTaskLibrary()
	return {
		spawn = function(fn, ...)
			return self:Spawn(fn, ...)
		end,
		defer = function(fn, ...)
			return self:Defer(fn, ...)
		end,
		delay = function(seconds, fn, ...)
			return self:Delay(seconds, fn, ...)
		end,
		wait = function(seconds)
			return self:Wait(seconds)
		end,
		cancel = function(thread)
			self:Cancel(thread)
		end,
	}
end

function Scheduler:CreateOsLibrary()
	return setmetatable({
		clock = function()
			return self.Now
		end,
		time = function()
			return 1_700_000_000 + math.floor(self.Now)
		end,
	}, { __index = os })
end

return Scheduler
