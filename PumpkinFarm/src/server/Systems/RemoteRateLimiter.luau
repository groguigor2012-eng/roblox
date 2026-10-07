--!strict
--[[
	RemoteRateLimiter
	Path: ServerScriptService.Server.Systems.RemoteRateLimiter

	Per-player, per-remote token buckets. RemoteService consults it before decoding a
	payload, so spam is rejected at the cheapest possible point.

	Dependencies: Shared.Classes.TokenBucket

	API:
		RemoteRateLimiter.new(limits: { [remoteName]: { Capacity, Refill } }) -> limiter
		limiter:Check(player, remoteName, now) -> boolean
		limiter:RemovePlayer(player)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TokenBucket = require(ReplicatedStorage.Shared.Classes.TokenBucket)

local DEFAULT_LIMIT = { Capacity = 5, Refill = 2 }

local RemoteRateLimiter = {}
RemoteRateLimiter.__index = RemoteRateLimiter

export type Limit = { Capacity: number, Refill: number }

function RemoteRateLimiter.new(limits: { [string]: Limit })
	return setmetatable({
		_limits = limits,
		_buckets = {} :: { [Player]: { [string]: TokenBucket.TokenBucket } },
	}, RemoteRateLimiter)
end

function RemoteRateLimiter:Check(player: Player, remoteName: string, now: number): boolean
	local perPlayer = self._buckets[player]
	if perPlayer == nil then
		perPlayer = {}
		self._buckets[player] = perPlayer
	end
	local bucket = perPlayer[remoteName]
	if bucket == nil then
		local limit = self._limits[remoteName] or DEFAULT_LIMIT
		bucket = TokenBucket.new(limit.Capacity, limit.Refill, now)
		perPlayer[remoteName] = bucket
	end
	return bucket:TryConsume(now)
end

function RemoteRateLimiter:RemovePlayer(player: Player)
	self._buckets[player] = nil
end

return RemoteRateLimiter
