-- Common security layer for every client -> server remote:
--   * argument count/type validation (handlers only receive cleaned values)
--   * "profile loaded" gate
--   * per-player, per-action rate limits
--   * per-player transaction locks (no two state-changing requests interleave)
--   * pcall isolation so a handler error never leaks or leaves partial state
--   * throttled logging of suspicious requests
--
-- Request remotes always return a Result: { ok: boolean, code: string, message: string?, data: any? }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Config.GameConfig)
local RemoteNames = require(ReplicatedStorage.Shared.RemoteNames)
local RateLimiter = require(script.Parent.RateLimiter)
local Remotes = require(script.Parent.Remotes)

local Codes = RemoteNames.Codes

export type Result = { ok: boolean, code: string, message: string?, data: any? }

export type FunctionSpec = {
	action: string, -- rate-limit key (GameConfig.RateLimits)
	args: { (any) -> (boolean, any) },
	requireReady: boolean?, -- default true
	lock: boolean?, -- serialise with the player's other locked requests (default true)
}

local RemoteSecurityService = {}
RemoteSecurityService.Name = "RemoteSecurityService"

local Services
local limiter = RateLimiter.new(os.clock)
local locks: { [Player]: boolean } = {}
local lastLogAt: { [Player]: number } = {}
local suppressedLogs: { [Player]: number } = {}

local LOG_INTERVAL = 2

function RemoteSecurityService.result(ok: boolean, code: string, message: string?, data: any?): Result
	return { ok = ok, code = code, message = message, data = data }
end

function RemoteSecurityService.ok(data: any?, message: string?): Result
	return { ok = true, code = Codes.Ok, message = message, data = data }
end

function RemoteSecurityService.fail(code: string, message: string?, data: any?): Result
	return { ok = false, code = code, message = message, data = data }
end

-- Logs a rejected or suspicious request, at most once every LOG_INTERVAL seconds per player.
function RemoteSecurityService.report(player: Player, action: string, reason: string)
	if not GameConfig.Debug.LogSuspicious then
		return
	end
	local now = os.clock()
	if lastLogAt[player] and now - lastLogAt[player] < LOG_INTERVAL then
		suppressedLogs[player] = (suppressedLogs[player] or 0) + 1
		return
	end
	local suppressed = suppressedLogs[player] or 0
	suppressedLogs[player] = 0
	lastLogAt[player] = now
	local suffix = if suppressed > 0 then ` (+{suppressed} suppressed)` else ""
	warn(`[Security] {player.Name} ({player.UserId}) {action}: {reason}{suffix}`)
end

function RemoteSecurityService.allow(player: Player, action: string): boolean
	local limit = GameConfig.RateLimits[action]
	if not limit then
		warn(`[Security] No rate limit configured for "{action}"; denying by default`)
		return false
	end
	return limiter:allow(player, action, limit)
end

-- Runs fn while holding the player's transaction lock. Returns a Busy result if another
-- locked request from the same player is still running (e.g. two tame requests at once).
function RemoteSecurityService.withLock(player: Player, fn: () -> Result): Result
	if locks[player] then
		return RemoteSecurityService.fail(Codes.Busy, "Please wait a moment.")
	end
	locks[player] = true
	local ok, result = pcall(fn)
	locks[player] = nil
	if not ok then
		warn(`[Security] handler error for {player.Name}: {result}`)
		return RemoteSecurityService.fail(Codes.ServerError, "Something went wrong. Nothing was changed.")
	end
	return result
end

local function validateArgs(player: Player, action: string, validators, ...): (boolean, { any })
	local count = select("#", ...)
	if count > #validators then
		RemoteSecurityService.report(player, action, `too many arguments ({count})`)
		return false, {}
	end
	local clean = {}
	for index, validator in validators do
		local ok, value = validator((select(index, ...)))
		if not ok then
			RemoteSecurityService.report(player, action, `invalid argument #{index} ({typeof((select(index, ...)))})`)
			return false, {}
		end
		clean[index] = value
	end
	return true, clean
end

function RemoteSecurityService.bindFunction(name: string, spec: FunctionSpec, handler: (Player, ...any) -> Result)
	local remote = Remotes.get(name)
	local requireReady = spec.requireReady ~= false
	local useLock = spec.lock ~= false
	remote.OnServerInvoke = function(player: Player, ...)
		local valid, args = validateArgs(player, spec.action, spec.args, ...)
		if not valid then
			return RemoteSecurityService.fail(Codes.BadRequest, "Invalid request.")
		end
		if requireReady and not Services.PlayerStateService.isReady(player) then
			return RemoteSecurityService.fail(Codes.NotReady, "Your data is still loading.")
		end
		if not RemoteSecurityService.allow(player, spec.action) then
			RemoteSecurityService.report(player, spec.action, "rate limited")
			return RemoteSecurityService.fail(Codes.RateLimited)
		end
		local function run(): Result
			local result = handler(player, table.unpack(args, 1, #spec.args))
			if type(result) ~= "table" then
				return RemoteSecurityService.fail(Codes.ServerError, "Something went wrong.")
			end
			return result
		end
		if useLock then
			return RemoteSecurityService.withLock(player, run)
		end
		local ok, result = pcall(run)
		if not ok then
			warn(`[Security] {name} handler error for {player.Name}: {result}`)
			return RemoteSecurityService.fail(Codes.ServerError, "Something went wrong.")
		end
		return result
	end
end

-- Client -> server events (fire-and-forget). Invalid or excessive packets are dropped.
function RemoteSecurityService.bindEvent(name: string, spec: FunctionSpec, handler: (Player, ...any) -> ())
	local remote = Remotes.get(name)
	local requireReady = spec.requireReady ~= false
	remote.OnServerEvent:Connect(function(player: Player, ...)
		if not RemoteSecurityService.allow(player, spec.action) then
			return -- silently drop; streams like MountInput legitimately burst
		end
		local valid, args = validateArgs(player, spec.action, spec.args, ...)
		if not valid then
			return
		end
		if requireReady and not Services.PlayerStateService.isReady(player) then
			return
		end
		local ok, err = pcall(handler, player, table.unpack(args, 1, #spec.args))
		if not ok then
			warn(`[Security] {name} handler error for {player.Name}: {err}`)
		end
	end)
end

-- Server-side gate for world interactions (ProximityPrompts) that don't go through a
-- remote but still need the same checks.
function RemoteSecurityService.checkInteraction(player: Player, action: string): (boolean, string?)
	if not Services.PlayerStateService.isReady(player) then
		return false, "Your data is still loading."
	end
	if not RemoteSecurityService.allow(player, action) then
		RemoteSecurityService.report(player, action, "rate limited")
		return false, nil -- no message: avoid notification spam
	end
	return true, nil
end

-- Distance from the player's character root to a world position, or nil if the character
-- is missing/dead.
function RemoteSecurityService.distanceTo(player: Player, position: Vector3): number?
	local root = Services.PlayerStateService.getRoot(player)
	if not root then
		return nil
	end
	return (root.Position - position).Magnitude
end

function RemoteSecurityService.init(services)
	Services = services
end

function RemoteSecurityService.start()
	Players.PlayerRemoving:Connect(function(player)
		limiter:forget(player)
		locks[player] = nil
		lastLogAt[player] = nil
		suppressedLogs[player] = nil
	end)
end

return RemoteSecurityService
