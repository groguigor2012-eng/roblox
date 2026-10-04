-- Minimal stand-in for Roblox's Random (LCG; quality irrelevant for tests).
local Random = {}
Random.__index = Random
function Random.new(seed)
	return setmetatable({ s = (seed or 1) % 2147483647 + 1 }, Random)
end
function Random:_next()
	self.s = (self.s * 48271) % 2147483647
	return self.s / 2147483647
end
function Random:NextNumber(a, b)
	local r = self:_next()
	if a then return a + (b - a) * r end
	return r
end
function Random:NextInteger(a, b)
	return math.min(b, a + math.floor(self:_next() * (b - a + 1)))
end
return Random
