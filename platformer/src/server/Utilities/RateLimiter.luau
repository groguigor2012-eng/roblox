--!strict
-- Token-bucket rate limiter keyed by any value (usually a Player).
-- Each key holds up to Capacity tokens, refilled at RefillPerSecond. A request
-- spends one token and is rejected when none are left, so bursts are capped
-- at Capacity and sustained rate at RefillPerSecond. Memory is bounded by the
-- number of live keys; call Remove when a player leaves.

local RateLimiter = {}
RateLimiter.__index = RateLimiter

type Bucket = { Tokens: number, Updated: number }

type Fields = {
	_capacity: number,
	_refill: number,
	_clock: () -> number,
	_buckets: { [any]: Bucket },
}

export type RateLimiter = typeof(setmetatable({} :: Fields, RateLimiter))

function RateLimiter.new(capacity: number, refillPerSecond: number, clock: (() -> number)?): RateLimiter
	assert(capacity >= 1, "RateLimiter capacity must be >= 1")
	assert(refillPerSecond > 0, "RateLimiter refill must be > 0")
	local self: Fields = {
		_capacity = capacity,
		_refill = refillPerSecond,
		_clock = clock or os.clock,
		_buckets = {},
	}
	return setmetatable(self, RateLimiter)
end

function RateLimiter.Allow(self: RateLimiter, key: any): boolean
	local now = self._clock()
	local bucket = self._buckets[key]
	if not bucket then
		bucket = { Tokens = self._capacity, Updated = now }
		self._buckets[key] = bucket
	else
		bucket.Tokens = math.min(self._capacity, bucket.Tokens + (now - bucket.Updated) * self._refill)
		bucket.Updated = now
	end
	if bucket.Tokens >= 1 then
		bucket.Tokens -= 1
		return true
	end
	return false
end

function RateLimiter.Remove(self: RateLimiter, key: any)
	self._buckets[key] = nil
end

return RateLimiter
