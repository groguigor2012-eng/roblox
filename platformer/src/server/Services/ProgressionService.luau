--!strict
-- The only bridge between gameplay events and persisted progression.
-- Server code only: no remote reaches this module, and every call names a
-- source that must be in GameConfig.Progression.TrustedRewardSources.
--
-- Duplicate protection: ClaimCollectible checks and records the claim and
-- grants the reward without yielding, so Luau runs it to completion and two
-- requests for the same item can never interleave.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Utilities.Logger)
local Types = require(Shared.Types)

local PlayerDataService = require(script.Parent.PlayerDataService)

type CurrencyType = Types.CurrencyType

export type RewardResult = {
	Success: boolean,
	Reason: string?,
	NewTotal: number?,
}

export type CollectibleClaim = {
	-- Stable id (persistent or session) or a "runtime:" key for id-less items.
	Key: string,
	-- true: stored in PlayerData.CollectedCollectibles; false: this session only.
	Persistent: boolean,
	CurrencyType: CurrencyType,
	Amount: number,
	Source: string,
}

local RUNTIME_KEY_PREFIX = "runtime:"

local logger = Logger.new("ProgressionService")

local ProgressionService = {}

-- Non-persistent claims, per player, for this server session only.
local sessionClaims: { [Player]: { [string]: boolean } } = {}
local started = false

local function isTrustedSource(source: any): boolean
	return type(source) == "string" and GameConfig.Progression.TrustedRewardSources[source] == true
end

local function reject(player: Player, reason: string, fields: { [string]: any }?): RewardResult
	local logFields: { [string]: any } = fields or {}
	logFields.UserId = player.UserId
	logFields.Reason = reason
	if reason == "AlreadyCollected" or reason == "DataNotReady" then
		logger:Debug("RewardRejected", logFields)
	else
		logger:Warn("RewardRejected", logFields)
	end
	return { Success = false, Reason = reason }
end

-- Grants currency with no collection bookkeeping.
function ProgressionService.GrantCurrency(
	player: Player,
	currencyType: CurrencyType,
	amount: number,
	source: string
): RewardResult
	if not isTrustedSource(source) then
		return reject(player, "UntrustedSource", { Source = source })
	end
	local ok, result = PlayerDataService.AddCurrency(player, currencyType, amount, source)
	if not ok then
		return reject(player, tostring(result), { Type = currencyType, Amount = amount, Source = source })
	end
	return { Success = true, NewTotal = result :: number }
end

-- Whether this player already claimed the key (persistent or this session).
function ProgressionService.HasClaimed(player: Player, key: string, persistent: boolean): boolean
	if persistent then
		return PlayerDataService.HasCollected(player, key) == true
	end
	local claims = sessionClaims[player]
	return claims ~= nil and claims[key] == true
end

-- Records the claim and grants its reward atomically (no yields).
function ProgressionService.ClaimCollectible(player: Player, claim: CollectibleClaim): RewardResult
	if not isTrustedSource(claim.Source) then
		return reject(player, "UntrustedSource", { Source = claim.Source, Key = claim.Key })
	end
	local valid, invalidReason = PlayerDataService.ValidateCurrencyGrant(claim.CurrencyType, claim.Amount)
	if not valid then
		return reject(player, invalidReason :: string, { Key = claim.Key })
	end
	if not PlayerDataService.IsPlayerDataReady(player) then
		return reject(player, "DataNotReady", { Key = claim.Key })
	end

	if claim.Persistent then
		local marked, markReason = PlayerDataService.MarkCollected(player, claim.Key)
		if not marked then
			return reject(player, markReason or "MarkFailed", { Key = claim.Key })
		end
	else
		local claims = sessionClaims[player]
		if not claims then
			claims = {}
			sessionClaims[player] = claims
		end
		if claims[claim.Key] then
			return reject(player, "AlreadyCollected", { Key = claim.Key })
		end
		claims[claim.Key] = true
	end

	local ok, result = PlayerDataService.AddCurrency(player, claim.CurrencyType, claim.Amount, claim.Source)
	if not ok then
		-- Validation passed above, so this means data became unavailable.
		if claim.Persistent then
			PlayerDataService.UnmarkCollected(player, claim.Key)
		else
			local claims = sessionClaims[player]
			if claims then
				claims[claim.Key] = nil
			end
		end
		logger:Error("ClaimRolledBack", { UserId = player.UserId, Key = claim.Key, Reason = result })
		return { Success = false, Reason = tostring(result) }
	end
	return { Success = true, NewTotal = result :: number }
end

-- Stable ids the player has claimed: persisted ids plus this session's
-- non-persistent stable ids (generated "runtime:" keys are excluded).
function ProgressionService.GetClaimedIds(player: Player): { string }
	local ids = PlayerDataService.GetCollectedIds(player) or {}
	local claims = sessionClaims[player]
	if claims then
		for key in claims do
			if string.sub(key, 1, #RUNTIME_KEY_PREFIX) ~= RUNTIME_KEY_PREFIX then
				table.insert(ids, key)
			end
		end
	end
	return ids
end

ProgressionService.RuntimeKeyPrefix = RUNTIME_KEY_PREFIX

function ProgressionService.Start()
	assert(not started, "ProgressionService already started")
	started = true
	Players.PlayerRemoving:Connect(function(player)
		sessionClaims[player] = nil
	end)
end

return ProgressionService
