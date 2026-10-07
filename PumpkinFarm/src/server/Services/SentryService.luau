--!strict
--[[
	SentryService
	Path: ServerScriptService.Server.Services.SentryService

	Per-match registry of sentries plus ONE update loop (10 Hz) that drives every
	sentry in every match, instead of a Heartbeat connection per turret.

	Dependencies: Sentry, MatchState

	API:
		SentryService:InitMatch(match) / CleanupMatch(match)
		SentryService:Create(match, definition, cframe, owner, onDepleted) -> Sentry
		SentryService:Remove(sentry)
		SentryService:GetSentries(match) -> { Sentry }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MatchState = require(ReplicatedStorage.Shared.Constants.MatchState)

local Server = script:FindFirstAncestor("Server") :: Instance
local Sentry = require(Server.Classes.Sentry)

local UPDATE_INTERVAL = 0.1

local SentryService = {}

local states: { [any]: { [string]: any } } = {}

function SentryService:Init() end

function SentryService:Start()
	task.spawn(function()
		while true do
			task.wait(UPDATE_INTERVAL)
			local now = os.clock()
			for match, sentries in states do
				local state = match:GetState()
				if state == MatchState.WaveActive or state == MatchState.BossWave then
					for _, sentry in sentries do
						local ok, err = pcall(sentry.Update, sentry, now)
						if not ok then
							warn(`[SentryService] sentry {sentry.Uid} failed: {err}`)
						end
					end
				end
			end
		end
	end)
end

function SentryService:InitMatch(match: any)
	states[match] = {}
end

function SentryService:CleanupMatch(match: any)
	local sentries = states[match]
	states[match] = nil
	if sentries then
		for _, sentry in sentries do
			sentry:Destroy()
		end
	end
end

function SentryService:Create(match: any, definition: any, cframe: CFrame, owner: Player?, onDepleted: (any) -> ()): any
	local sentries = states[match]
	assert(sentries, "[SentryService] match not initialised")
	local sentry = Sentry.new(match, definition, cframe, owner, onDepleted)
	sentries[sentry.Uid] = sentry
	return sentry
end

function SentryService:Remove(sentry: any)
	local sentries = states[sentry.Match]
	if sentries then
		sentries[sentry.Uid] = nil
	end
	sentry:Destroy()
end

function SentryService:GetSentries(match: any): { any }
	local list = {}
	for _, sentry in states[match] or {} do
		table.insert(list, sentry)
	end
	return list
end

return SentryService
