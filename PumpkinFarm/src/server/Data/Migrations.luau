--!strict
--[[
	Migrations
	Path: ServerScriptService.Server.Data.Migrations

	Ordered schema migrations. Steps[n] upgrades a profile from Version n to n + 1.
	Run happens BEFORE template reconciliation, so a migration sees the raw stored data.

	Version 0 means "no Version key" (data written before versioning existed).

	A profile whose Version is newer than CurrentVersion was written by a newer server
	build (e.g. during a rolling update). It is refused instead of loaded, because
	saving it from an older build could silently drop fields it does not know about.

	To add a schema change:
		1. bump CurrentVersion and ProfileTemplate.Version
		2. add Steps[old] = function(data) ... end that converts the old shape
		3. add a test case in tests/specs/data_spec.luau

	API:
		Migrations.CurrentVersion
		Migrations.Run(data) -> (ok: boolean, reason: string?)   -- mutates data in place
]]

local Migrations = {}

Migrations.CurrentVersion = 1

local Steps: { [number]: (data: { [string]: any }) -> () } = {
	-- 0 -> 1: early builds stored UnlockedCostumes as an array of ids and kept
	-- Candies under "Candy". Convert both to the current shape.
	[0] = function(data)
		local costumes = data.UnlockedCostumes
		if type(costumes) == "table" and #costumes > 0 then
			local set = {}
			for _, costumeId in costumes do
				if type(costumeId) == "string" then
					set[costumeId] = true
				end
			end
			data.UnlockedCostumes = set
		end
		if data.Candies == nil and type(data.Candy) == "number" then
			data.Candies = data.Candy
		end
		data.Candy = nil
	end,
}

function Migrations.Run(data: { [string]: any }): (boolean, string?)
	local version = data.Version
	if version == nil then
		version = 0
	end
	if type(version) ~= "number" or version % 1 ~= 0 or version < 0 then
		return false, `invalid profile version {tostring(version)}`
	end
	if version > Migrations.CurrentVersion then
		return false, `profile version {version} is newer than server version {Migrations.CurrentVersion}`
	end

	while version < Migrations.CurrentVersion do
		local step = Steps[version]
		if step == nil then
			return false, `missing migration step from version {version}`
		end
		step(data)
		version += 1
		data.Version = version
	end
	return true, nil
end

return Migrations
