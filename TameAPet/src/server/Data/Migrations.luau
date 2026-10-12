--!strict
-- Profile schema migrations. Each step upgrades data from version N to N + 1 in place.
-- To change the schema: bump ProfileSchema.CURRENT_VERSION, add Steps[old] below, and add
-- a test in tests/data_spec.luau.

local ProfileSchema = require(script.Parent.ProfileSchema)

local Migrations = {}

Migrations.Steps = {
	-- 0 -> 1: profiles written before versioning existed (prototype builds) stored coins
	-- under `coins` and pets as an array. Convert them to the canonical shape.
	[0] = function(data: any)
		if data.currency == nil and type(data.coins) == "number" then
			data.currency = data.coins
		end
		data.coins = nil
		if type(data.pets) == "table" and #data.pets > 0 then
			local byId = {}
			for index, pet in data.pets do
				if type(pet) == "table" then
					local id = if type(pet.id) == "string" then pet.id else `legacy-{index}`
					pet.id = id
					byId[id] = pet
				end
			end
			data.pets = byId
		end
	end,
} :: { [number]: (any) -> () }

export type MigrationResult = "Ok" | "Newer" | "MissingStep"

-- Brand new profiles are created from the template and already carry the current version.
function Migrations.run(data: any): (MigrationResult, number)
	local version = if type(data.schemaVersion) == "number" then data.schemaVersion else 0
	if version > ProfileSchema.CURRENT_VERSION then
		-- Saved by a newer server build. Refuse to touch it rather than downgrade it.
		return "Newer", version
	end
	while version < ProfileSchema.CURRENT_VERSION do
		local step = Migrations.Steps[version]
		if not step then
			return "MissingStep", version
		end
		step(data)
		version += 1
		data.schemaVersion = version
	end
	return "Ok", version
end

return Migrations
