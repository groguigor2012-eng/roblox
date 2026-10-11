--!strict
-- DataStore operations for one player's record, with session locking.
-- Every read-modify-write goes through UpdateAsync, so the lock check and the
-- write are atomic. Thrown errors are retried by DataStoreRetry.
--
-- The store argument is an adapter with UpdateAsync(key, transform); the
-- live adapter wraps a GlobalDataStore and tests pass MemoryDataStore.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataSchema = require(script.Parent.DataSchema)
local DataStoreRetry = require(script.Parent.DataStoreRetry)
local SessionLock = require(script.Parent.SessionLock)
local Types = require(ReplicatedStorage.Shared.Types)

type PlayerData = Types.PlayerData

export type Store = {
	UpdateAsync: (self: any, key: string, transform: (stored: any, keyInfo: any) -> (any, { number }?)) -> any,
}

export type Options = {
	JobId: string,
	PlaceId: number,
	LockTimeout: number,
	Now: () -> number,
	Retry: DataStoreRetry.Options,
}

export type AcquireStatus = "Acquired" | "Locked" | "FutureSchema" | "Failed"

export type AcquireResult = {
	Status: AcquireStatus,
	Data: PlayerData?,
	Report: DataSchema.NormalizeReport?,
	-- True when the lock belonged to another server that stopped refreshing it.
	TookExpiredLock: boolean,
	LockHolder: string?,
	Error: string?,
}

export type WriteStatus = "Saved" | "LostLock" | "Failed"

export type WriteResult = {
	Status: WriteStatus,
	Error: string?,
}

local RECORD_FORMAT = 1

local ProfileStore = {}

-- Splits a stored value into (raw player data, session). A bare table with
-- no wrapper is the legacy layout (data stored directly, never locked).
function ProfileStore.Unwrap(stored: any): (any, any)
	if type(stored) ~= "table" then
		return stored, nil
	end
	if stored.FormatVersion ~= nil or stored.Data ~= nil or stored.Session ~= nil then
		return stored.Data, stored.Session
	end
	return stored, nil
end

function ProfileStore.Acquire(store: Store, key: string, userId: number, options: Options): AcquireResult
	local outcome: AcquireResult = { Status = "Failed", TookExpiredLock = false, Error = "transform not run" }

	local ok, result = DataStoreRetry.Run(`Acquire {key}`, function()
		return (store:UpdateAsync(key, function(stored: any)
			local rawData, session = ProfileStore.Unwrap(stored)
			local now = options.Now()
			local lockState = SessionLock.Evaluate(session, options.JobId, now, options.LockTimeout)
			if lockState == "HeldByOther" then
				outcome = {
					Status = "Locked",
					TookExpiredLock = false,
					LockHolder = tostring(session.JobId),
				}
				return nil
			end

			local data, report = DataSchema.Normalize(rawData)
			if report.Status == "FutureSchema" then
				outcome = { Status = "FutureSchema", TookExpiredLock = false, Report = report }
				return nil
			end

			outcome = {
				Status = "Acquired",
				Data = data,
				Report = report,
				TookExpiredLock = lockState == "Expired",
			}
			local previousSave = if type(stored) == "table" and type(stored.LastSaved) == "number"
				then stored.LastSaved
				else nil
			return {
				FormatVersion = RECORD_FORMAT,
				Data = DataSchema.Copy(data),
				Session = SessionLock.Make(options.JobId, options.PlaceId, now),
				LastSaved = previousSave,
			},
				{ userId }
		end))
	end, options.Retry)

	if not ok then
		return { Status = "Failed", TookExpiredLock = false, Error = tostring(result) }
	end
	if outcome.Status == "Acquired" and result == nil then
		return {
			Status = "Failed",
			TookExpiredLock = false,
			Error = "UpdateAsync returned nil after the lock transform succeeded",
		}
	end
	return outcome
end

-- Writes a snapshot if we still own the lock. release = true also clears the
-- lock. Never writes over another server's session.
function ProfileStore.Write(
	store: Store,
	key: string,
	userId: number,
	snapshot: PlayerData,
	release: boolean,
	options: Options
): WriteResult
	local outcome: WriteResult = { Status = "Failed", Error = "transform not run" }
	local attempt = 0

	local ok, result = DataStoreRetry.Run(`Write {key}`, function()
		attempt += 1
		return (store:UpdateAsync(key, function(stored: any)
			local _, session = ProfileStore.Unwrap(stored)
			local now = options.Now()
			local lockState = SessionLock.Evaluate(session, options.JobId, now, options.LockTimeout)
			if lockState ~= "Owned" then
				if release and lockState == "Free" and attempt > 1 then
					-- An earlier attempt's release may have committed before the
					-- call errored. Either way the lock is no longer ours, so
					-- writing again would be wrong; nothing is lost.
					outcome = { Status = "Saved" }
				else
					outcome = {
						Status = "LostLock",
						Error = if SessionLock.IsValidSession(session)
							then `lock held by {session.JobId}`
							else "lock is free",
					}
				end
				return nil
			end
			outcome = { Status = "Saved" }
			return {
				FormatVersion = RECORD_FORMAT,
				Data = snapshot,
				Session = if release then nil else SessionLock.Make(options.JobId, options.PlaceId, now),
				LastSaved = now,
			},
				{ userId }
		end))
	end, options.Retry)

	if not ok then
		return { Status = "Failed", Error = tostring(result) }
	end
	return outcome
end

return ProfileStore
