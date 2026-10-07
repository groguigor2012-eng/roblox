--!strict
--[[
	TokenBucket
	Path: ReplicatedStorage.Shared.Classes.TokenBucket

	Classic token-bucket limiter: holds up to `capacity` tokens and refills at
	`refillPerSecond`. RemoteRateLimiter keeps one bucket per (player, remote).
	Time is passed in explicitly so the limiter is deterministic and unit-testable.

	Dependencies: none.

	API:
		TokenBucket.new(capacity, refillPerSecond, now) -> TokenBucket
		:TryConsume(now, cost?) -> boolean
		:GetTokens(now) -> number
]]

local TokenBucket = {}
TokenBucket.__index = TokenBucket

export type TokenBucket = typeof(setmetatable(
	{} :: {
		Capacity: number,
		RefillPerSecond: number,
		_tokens: number,
		_updatedAt: number,
	},
	TokenBucket
))

function TokenBucket.new(capacity: number, refillPerSecond: number, now: number): TokenBucket
	assert(capacity > 0, "TokenBucket capacity must be positive")
	assert(refillPerSecond >= 0, "TokenBucket refill must not be negative")
	return setmetatable({
		Capacity = capacity,
		RefillPerSecond = refillPerSecond,
		_tokens = capacity,
		_updatedAt = now,
	}, TokenBucket)
end

function TokenBucket._refill(self: TokenBucket, now: number)
	local elapsed = math.max(0, now - self._updatedAt)
	self._tokens = math.min(self.Capacity, self._tokens + elapsed * self.RefillPerSecond)
	self._updatedAt = now
end

function TokenBucket.TryConsume(self: TokenBucket, now: number, cost: number?): boolean
	local amount = cost or 1
	self:_refill(now)
	if self._tokens >= amount then
		self._tokens -= amount
		return true
	end
	return false
end

function TokenBucket.GetTokens(self: TokenBucket, now: number): number
	self:_refill(now)
	return self._tokens
end

return TokenBucket
