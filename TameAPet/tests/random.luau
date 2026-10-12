-- Deterministic stand-in for Roblox's Random (xorshift), enough for NextNumber/NextInteger.
local Random = {}
Random.__index = Random

function Random.new(seed: number?)
	local state = math.floor(seed or os.clock() * 1e6) % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	return setmetatable({ state = state }, Random)
end

function Random:_next(): number
	-- Park-Miller minimal standard generator.
	self.state = (self.state * 48271) % 2147483647
	return self.state / 2147483647
end

function Random:NextNumber(min: number?, max: number?): number
	local lo, hi = min or 0, max or 1
	return lo + (hi - lo) * self:_next()
end

function Random:NextInteger(min: number, max: number): number
	return min + math.floor(self:_next() * (max - min + 1))
end

return Random
