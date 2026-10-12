--!strict
-- Sliding-window rate limiter keyed by (player key, action). Pure apart from the injected
-- clock so it can be unit-tested.

export type Limit = { count: number, window: number }

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type RateLimiter = typeof(setmetatable(
	{} :: { _clock: () -> number, _buckets: { [any]: { [string]: { number } } } },
	RateLimiter
))

function RateLimiter.new(clock: () -> number): RateLimiter
	return setmetatable({ _clock = clock, _buckets = {} }, RateLimiter)
end

-- Returns true and records the request if within budget; false otherwise.
function RateLimiter.allow(self: RateLimiter, owner: any, action: string, limit: Limit): boolean
	local now = self._clock()
	local perOwner = self._buckets[owner]
	if not perOwner then
		perOwner = {}
		self._buckets[owner] = perOwner
	end
	local stamps = perOwner[action]
	if not stamps then
		stamps = {}
		perOwner[action] = stamps
	end
	-- Drop timestamps outside the window (oldest first).
	local cutoff = now - limit.window
	local keepFrom = 1
	while keepFrom <= #stamps and stamps[keepFrom] <= cutoff do
		keepFrom += 1
	end
	if keepFrom > 1 then
		table.move(stamps, keepFrom, #stamps, 1)
		for i = #stamps - keepFrom + 2, #stamps do
			stamps[i] = nil
		end
	end
	if #stamps >= limit.count then
		return false
	end
	table.insert(stamps, now)
	return true
end

function RateLimiter.forget(self: RateLimiter, owner: any)
	self._buckets[owner] = nil
end

return RateLimiter
