--[[
	Compiles every .luau file under src/ with the Luau compiler bundled in Lune and
	reports syntax errors. Run: lune run tests/compile_check.luau (from PumpkinFarm/)
]]
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local failures = 0
local checked = 0

local function walk(dir: string)
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			walk(path)
		elseif name:match("%.luau$") then
			checked += 1
			local source = fs.readFile(path)
			local ok, err = pcall(luau.compile, source, { debugName = path })
			if not ok then
				failures += 1
				print("SYNTAX: " .. path .. "\n  " .. tostring(err))
			end
		end
	end
end

walk("src")
print(`compiled {checked} files, {failures} failures`)
if failures > 0 then
	process.exit(1)
end
