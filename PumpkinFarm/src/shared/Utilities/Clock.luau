--!strict
--[[
	Clock
	Path: ReplicatedStorage.Shared.Utilities.Clock

	One time base for everything a client displays as a countdown (phase timers, effect
	expiry, door deadline). Workspace:GetServerTimeNow() is synchronised between server
	and clients, so the server can replicate an absolute "ends at" timestamp once and
	every client counts down locally with no per-second network traffic.

	API:
		Clock.Now() -> number
]]

local Workspace = game:GetService("Workspace")

local Clock = {}

function Clock.Now(): number
	return Workspace:GetServerTimeNow()
end

return Clock
