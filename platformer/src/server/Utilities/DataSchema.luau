--!strict
-- PlayerData schema: defaults, validation, normalisation and migrations.
--
-- Normalize never throws on bad stored data. It keeps every valid field and
-- repairs or drops only what is invalid, reporting each change:
--   New          nothing stored yet (first visit)
--   Ok           stored data was already valid
--   Repaired     some fields were fixed, dropped or migrated (see Issues)
--   FutureSchema SchemaVersion is newer than this server understands; the
--                caller must not write anything back
--   Corrupt      the stored value is not a table; nothing was recoverable

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local CollectibleConfig = require(Shared.Config.CollectibleConfig)
local DataConfig = require(Shared.Config.DataConfig)
local Types = require(Shared.Types)

type PlayerData = Types.PlayerData

export type NormalizeStatus = "New" | "Ok" | "Repaired" | "FutureSchema" | "Corrupt"

export type NormalizeReport = {
	Status: NormalizeStatus,
	Issues: { string },
	-- Schema version the data was migrated from, if a migration ran.
	MigratedFrom: number?,
}

local DataSchema = {}

DataSchema.CurrentVersion = DataConfig.SchemaVersion

local KNOWN_FIELDS: { [string]: boolean } = {
	SchemaVersion = true,
	Shards = true,
	PowerOrbs = true,
	CollectedCollectibles = true,
}

-- Migrations[n] upgrades a version-n table to version n + 1 in place.
-- Version 0 is the unversioned pre-release layout: power orbs were stored as
-- "Orbs" and collected ids as an array named "Collected".
DataSchema.Migrations = {
	[0] = function(data: { [string]: any })
		if data.PowerOrbs == nil and data.Orbs ~= nil then
			data.PowerOrbs = data.Orbs
		end
		data.Orbs = nil
		if data.CollectedCollectibles == nil and type(data.Collected) == "table" then
			local set: { [string]: boolean } = {}
			for _, id in data.Collected do
				if type(id) == "string" then
					set[id] = true
				end
			end
			data.CollectedCollectibles = set
		end
		data.Collected = nil
	end,
} :: { [number]: (data: { [string]: any }) -> () }

function DataSchema.Default(): PlayerData
	return {
		SchemaVersion = DataSchema.CurrentVersion,
		Shards = 0,
		PowerOrbs = 0,
		CollectedCollectibles = {},
	}
end

function DataSchema.IsValidCollectibleId(id: any): boolean
	return type(id) == "string"
		and #id > 0
		and #id <= CollectibleConfig.Ids.MaxLength
		and string.match(id, CollectibleConfig.Ids.Pattern) ~= nil
end

function DataSchema.IsCurrencyType(value: any): boolean
	return value == "Shards" or value == "PowerOrbs"
end

-- Deep copy; used for save snapshots and read-only views.
function DataSchema.Copy(data: PlayerData): PlayerData
	return {
		SchemaVersion = data.SchemaVersion,
		Shards = data.Shards,
		PowerOrbs = data.PowerOrbs,
		CollectedCollectibles = table.clone(data.CollectedCollectibles),
	}
end

local function sanitizeCurrency(value: any, field: string, issues: { string }): number
	if value == nil then
		table.insert(issues, `{field} missing; set to 0`)
		return 0
	end
	if type(value) ~= "number" or value ~= value then
		table.insert(issues, `{field} was {typeof(value)} {tostring(value)}; set to 0`)
		return 0
	end
	if value < 0 then
		table.insert(issues, `{field} was negative ({value}); set to 0`)
		return 0
	end
	if value > DataConfig.MaxCurrency then
		table.insert(issues, `{field} above cap ({value}); clamped`)
		return DataConfig.MaxCurrency
	end
	if math.floor(value) ~= value then
		table.insert(issues, `{field} was fractional ({value}); floored`)
		return math.floor(value)
	end
	return value
end

local function sanitizeCollected(value: any, issues: { string }): { [string]: boolean }
	if value == nil then
		table.insert(issues, "CollectedCollectibles missing; set to empty")
		return {}
	end
	if type(value) ~= "table" then
		table.insert(issues, `CollectedCollectibles was {typeof(value)}; set to empty`)
		return {}
	end
	local ids: { string } = {}
	local seen: { [string]: boolean } = {}
	local dropped = 0
	for key, entry in value do
		local candidate: any = nil
		if type(key) == "number" then
			-- Array form (legacy layouts or an empty table round-tripped through JSON).
			candidate = entry
		elseif type(key) == "string" and entry == true then
			candidate = key
		end
		if DataSchema.IsValidCollectibleId(candidate) and not seen[candidate] then
			seen[candidate] = true
			table.insert(ids, candidate)
		else
			dropped += 1
		end
	end
	if dropped > 0 then
		table.insert(issues, `dropped {dropped} invalid or duplicate collectible id(s)`)
	end
	-- Sorted so truncation (if ever needed) is deterministic.
	table.sort(ids)
	local limit = DataConfig.MaxCollectedIds
	if #ids > limit then
		table.insert(issues, `collectible ids above cap ({#ids}); kept first {limit}`)
	end
	local set: { [string]: boolean } = {}
	for index = 1, math.min(#ids, limit) do
		set[ids[index]] = true
	end
	return set
end

function DataSchema.Normalize(raw: any): (PlayerData, NormalizeReport)
	local issues: { string } = {}
	if raw == nil then
		return DataSchema.Default(), { Status = "New", Issues = issues }
	end
	if type(raw) ~= "table" then
		table.insert(issues, `stored value is a {typeof(raw)}, expected table`)
		return DataSchema.Default(), { Status = "Corrupt", Issues = issues }
	end

	local version: number
	local storedVersion = raw.SchemaVersion
	if storedVersion == nil then
		version = 0
	elseif type(storedVersion) ~= "number" or storedVersion ~= math.floor(storedVersion) or storedVersion < 0 then
		table.insert(issues, `invalid SchemaVersion {tostring(storedVersion)}; treated as 0`)
		version = 0
	else
		version = storedVersion
	end

	if version > DataSchema.CurrentVersion then
		table.insert(issues, `SchemaVersion {version} is newer than {DataSchema.CurrentVersion}`)
		return DataSchema.Default(), { Status = "FutureSchema", Issues = issues }
	end

	local working: { [string]: any } = table.clone(raw)
	local migratedFrom: number? = nil
	while version < DataSchema.CurrentVersion do
		local migrate = DataSchema.Migrations[version]
		if not migrate then
			-- A missing step is a programming error, not bad data.
			error(`DataSchema has no migration from version {version}`)
		end
		migrate(working)
		migratedFrom = migratedFrom or version
		version += 1
	end
	if migratedFrom then
		table.insert(issues, `migrated from schema {migratedFrom}`)
	end

	local data: PlayerData = {
		SchemaVersion = DataSchema.CurrentVersion,
		Shards = sanitizeCurrency(working.Shards, "Shards", issues),
		PowerOrbs = sanitizeCurrency(working.PowerOrbs, "PowerOrbs", issues),
		CollectedCollectibles = sanitizeCollected(working.CollectedCollectibles, issues),
	}

	for key in working do
		if not KNOWN_FIELDS[key] then
			table.insert(issues, `dropped unknown field {tostring(key)}`)
		end
	end

	return data, {
		Status = if #issues > 0 then "Repaired" else "Ok",
		Issues = issues,
		MigratedFrom = migratedFrom,
	}
end

return DataSchema
