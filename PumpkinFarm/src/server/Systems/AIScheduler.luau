--!strict
--[[
	AIScheduler
	Path: ServerScriptService.Server.Systems.AIScheduler

	One Heartbeat drives every enemy in the server. Each agent declares its own think
	rate (UpdateInterval); the scheduler round-robins through agents that are due and
	stops after MaxUpdatesPerFrame, so a huge wave degrades into slightly slower
	thinking instead of frame spikes. Agent errors are isolated: the faulty agent is
	reported and removed through its OnSchedulerError hook, everything else keeps running.

	Agents must provide: UpdateInterval, Update(now, dt), OnSchedulerError(err).

	Dependencies: none

	API:
		AIScheduler.new(maxUpdatesPerFrame) -> scheduler
		scheduler:Add(agent)
		scheduler:Remove(agent)
		scheduler:Start()
		scheduler:GetCount() -> number
]]

local RunService = game:GetService("RunService")

local AIScheduler = {}
AIScheduler.__index = AIScheduler

type Entry = { Agent: any, NextAt: number, LastAt: number }

function AIScheduler.new(maxUpdatesPerFrame: number)
	return setmetatable({
		_entries = {} :: { Entry },
		_index = {} :: { [any]: number },
		_cursor = 1,
		_budget = maxUpdatesPerFrame,
		_connection = nil :: RBXScriptConnection?,
	}, AIScheduler)
end

function AIScheduler:Add(agent: any)
	if self._index[agent] then
		return
	end
	local now = os.clock()
	table.insert(self._entries, {
		Agent = agent,
		-- Random phase so agents spawned together do not all think on the same frame.
		NextAt = now + math.random() * (agent.UpdateInterval or 0.2),
		LastAt = now,
	})
	self._index[agent] = #self._entries
end

function AIScheduler:Remove(agent: any)
	local index = self._index[agent]
	if index == nil then
		return
	end
	local entries = self._entries
	local last = #entries
	if index ~= last then
		entries[index] = entries[last]
		self._index[entries[index].Agent] = index
	end
	entries[last] = nil
	self._index[agent] = nil
end

function AIScheduler:GetCount(): number
	return #self._entries
end

function AIScheduler:_step()
	local entries = self._entries
	local count = #entries
	if count == 0 then
		return
	end
	local now = os.clock()
	local processed = 0
	local inspected = 0
	while inspected < count and processed < self._budget do
		if self._cursor > #entries then
			self._cursor = 1
		end
		local entry = entries[self._cursor]
		self._cursor += 1
		inspected += 1
		if entry and now >= entry.NextAt then
			local agent = entry.Agent
			local dt = now - entry.LastAt
			entry.LastAt = now
			entry.NextAt = now + (agent.UpdateInterval or 0.2)
			processed += 1
			local ok, err = xpcall(agent.Update, debug.traceback, agent, now, dt)
			if not ok then
				warn(`[AIScheduler] agent update failed: {err}`)
				self:Remove(agent)
				pcall(agent.OnSchedulerError, agent, err)
			end
		end
	end
end

function AIScheduler:Start()
	if self._connection then
		return
	end
	self._connection = RunService.Heartbeat:Connect(function()
		self:_step()
	end)
end

return AIScheduler
