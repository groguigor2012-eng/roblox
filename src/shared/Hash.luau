--!strict
-- Deterministic integer hashing so every server (and every generation order)
-- produces the same world for a given Config.SEED.

local Config = require(script.Parent.Config)

local Hash = {}

local TWO32 = 4294967296

-- (a * b) mod 2^32 without losing precision in doubles.
local function mul32(a: number, b: number): number
	local lo = a % 65536
	local hi = (a - lo) / 65536
	return (lo * b + ((hi * b) % 65536) * 65536) % TWO32
end

-- Hash two grid coordinates plus a salt into a 32-bit unsigned integer.
function Hash.int(a: number, b: number, salt: number): number
	local n = (Config.SEED * 374761393 + a * 668265263 + b * 2246822519 + salt * 3266489917) % TWO32
	n = bit32.bxor(n, bit32.rshift(n, 15))
	n = mul32(n, 2246822519)
	n = bit32.bxor(n, bit32.rshift(n, 13))
	n = mul32(n, 3266489917)
	n = bit32.bxor(n, bit32.rshift(n, 16))
	return n
end

-- Same, mapped to [0, 1).
function Hash.unit(a: number, b: number, salt: number): number
	return Hash.int(a, b, salt) / TWO32
end

function Hash.random(a: number, b: number, salt: number): Random
	return Random.new(Hash.int(a, b, salt))
end

return Hash
