return function(H)
	local RemoteRateLimiter = H.Module("Server.Systems.RemoteRateLimiter")

	H.test("rate limiter isolates players and remotes", function()
		local limiter = RemoteRateLimiter.new({ RequestAttack = { Capacity = 2, Refill = 1 } })
		local alice, bob = {}, {}
		H.ok(limiter:Check(alice, "RequestAttack", 0))
		H.ok(limiter:Check(alice, "RequestAttack", 0))
		H.ok(not limiter:Check(alice, "RequestAttack", 0), "alice is throttled")
		H.ok(limiter:Check(bob, "RequestAttack", 0), "bob has his own bucket")
		H.ok(limiter:Check(alice, "RequestPlant", 0), "other remotes use separate buckets")
		limiter:RemovePlayer(alice)
		H.ok(limiter:Check(alice, "RequestAttack", 0), "state cleared on leave")
	end)

	H.test("spamming 100 attack requests in one second admits only a handful", function()
		local NetworkConfig = H.Module("Shared.Config.NetworkConfig")
		local limit = NetworkConfig.Remotes.RequestAttack.RateLimit
		local limiter = RemoteRateLimiter.new({ RequestAttack = limit })
		local player = {}
		local admitted = 0
		for i = 1, 100 do
			if limiter:Check(player, "RequestAttack", i / 100) then
				admitted += 1
			end
		end
		H.ok(admitted <= limit.Capacity + limit.Refill + 1, `admitted {admitted}`)
	end)
end
