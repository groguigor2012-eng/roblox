--[[
	Runs every spec in tests/specs with the headless harness.
	Usage (from PumpkinFarm/):  lune run tests/run.luau
]]
local fs = require("@lune/fs")
local process = require("@lune/process")
local H = require("./harness")

local specs = fs.readDir("tests/specs")
table.sort(specs)
for _, file in specs do
	if file:match("%.luau$") then
		local name = file:gsub("%.luau$", "")
		local spec = require("./specs/" .. name)
		spec(H)
	end
end

print(`{H.Results.passed} passed, {H.Results.failed} failed`)
if H.Results.failed > 0 then
	process.exit(1)
end
