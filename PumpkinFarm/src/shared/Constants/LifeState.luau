--!strict
--[[
	LifeState
	Path: ReplicatedStorage.Shared.Constants.LifeState

	Where a player is in the game flow. Owned by PlayerService (PlayerSession.LifeState)
	and mirrored to the Player "LifeState" attribute for UI.
]]

return table.freeze({
	Loading = "Loading", -- profile not loaded yet
	Lobby = "Lobby",
	Queued = "Queued",
	InMatch = "InMatch", -- alive inside a match
	Downed = "Downed", -- dead inside a match, waits for the wave to end
	Escaped = "Escaped", -- extracted; being returned to the lobby
})
