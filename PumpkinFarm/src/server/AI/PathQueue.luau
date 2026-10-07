--!strict
--[[
	PathQueue
	Path: ServerScriptService.Server.AI.PathQueue

	Server-wide limiter for Path:ComputeAsync. Pathfinding is the most expensive AI
	operation, so at most EnemyConfig.MaxConcurrentPathRequests computations run at once;
	the rest wait in FIFO order. A request whose owner died meanwhile is skipped
	through the `isStillWanted` callback.

	Dependencies: EnemyConfig

	API:
		PathQueue.Request(job: () -> (), isStillWanted: () -> boolean)
		PathQueue.GetPending() -> number
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EnemyConfig = require(ReplicatedStorage.Shared.Config.EnemyConfig)

type Job = { Run: () -> (), Wanted: () -> boolean }

local PathQueue = {}

local pending: { Job } = {}
local running = 0

local function pump()
	while running < EnemyConfig.MaxConcurrentPathRequests and #pending > 0 do
		local job = table.remove(pending, 1) :: Job
		if job.Wanted() then
			running += 1
			task.spawn(function()
				local ok, err = pcall(job.Run)
				if not ok then
					warn(`[PathQueue] path job failed: {err}`)
				end
				running -= 1
				pump()
			end)
		end
	end
end

function PathQueue.Request(job: () -> (), isStillWanted: () -> boolean)
	table.insert(pending, { Run = job, Wanted = isStillWanted })
	pump()
end

function PathQueue.GetPending(): number
	return #pending
end

return PathQueue
