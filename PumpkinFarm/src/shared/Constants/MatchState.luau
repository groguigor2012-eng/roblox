--!strict
--[[
	MatchState
	Path: ReplicatedStorage.Shared.Constants.MatchState

	Every state of the match lifecycle state machine (see Server.Classes.Match).
	Replicated to clients through the match folder's "State" attribute.
]]

local MatchState = table.freeze({
	Waiting = "Waiting", -- match created, players loading in
	Starting = "Starting", -- short intro countdown, loadouts granted
	Intermission = "Intermission", -- seed shop restocked, free building/planting time
	PreparingWave = "PreparingWave", -- "Wave N incoming" warning
	WaveActive = "WaveActive", -- regular wave in progress
	BossWave = "BossWave", -- wave that contains the Cursed Harvester
	WaveComplete = "WaveComplete", -- rewards, revive downed players
	Extraction = "Extraction", -- Escape Door is open, players decide
	ContinuePreparation = "ContinuePreparation", -- 30 s countdown after "Continue"
	MatchEnding = "MatchEnding", -- results shown, players returned to lobby
	Cleanup = "Cleanup", -- everything torn down, match removed
})

return MatchState
