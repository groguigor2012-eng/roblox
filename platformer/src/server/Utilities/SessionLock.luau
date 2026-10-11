--!strict
-- Pure session-lock rules, applied inside UpdateAsync transforms so every
-- check-and-write is atomic on Roblox's side.
--
-- A record's Session field names the server (JobId) that owns the player's
-- data and when it last refreshed the lock (os.time()). Rules:
--   Free        no valid Session: anyone may take it
--   Owned       Session.JobId is ours (regardless of age): we may write
--   Expired     another server's lock older than the timeout: treated as
--               abandoned (crashed server) and may be taken
--   HeldByOther another server's live lock: we must not write

local SessionLock = {}

export type Session = {
	JobId: string,
	PlaceId: number,
	LockedAt: number,
}

export type LockState = "Free" | "Owned" | "Expired" | "HeldByOther"

function SessionLock.IsValidSession(session: any): boolean
	return type(session) == "table"
		and type(session.JobId) == "string"
		and #session.JobId > 0
		and type(session.LockedAt) == "number"
		and session.LockedAt == session.LockedAt
end

function SessionLock.Evaluate(session: any, jobId: string, now: number, timeout: number): LockState
	if not SessionLock.IsValidSession(session) then
		return "Free"
	end
	if session.JobId == jobId then
		return "Owned"
	end
	-- Clock skew between servers can make age negative; that still counts as live.
	local age = now - session.LockedAt
	if age > timeout then
		return "Expired"
	end
	return "HeldByOther"
end

function SessionLock.Make(jobId: string, placeId: number, now: number): Session
	return {
		JobId = jobId,
		PlaceId = placeId,
		LockedAt = now,
	}
end

return SessionLock
