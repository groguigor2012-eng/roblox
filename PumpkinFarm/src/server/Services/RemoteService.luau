--!strict
--[[
	RemoteService
	Path: ServerScriptService.Server.Services.RemoteService

	Owns every RemoteEvent / RemoteFunction. Instances are created from NetworkConfig
	under ReplicatedStorage.Remotes during Init, so the network surface is declared in
	exactly one place. Every client->server call passes through one guarded pipeline:

		1. sender must still be in the game
		2. rate limit (token bucket per player per remote)
		3. argument count + schema validation (Shared.Utilities.Validate)
		4. handler runs inside pcall; errors become ServerError, never a crash
		5. violations (spam / malformed) are counted per player

	Handlers receive validated arguments only. They express INTENT; the owning service
	decides outcomes.

	Dependencies: NetworkConfig, ResultCode, Result, Validate, RemoteRateLimiter

	API:
		RemoteService:OnEvent(name, handler(player, ...))
		RemoteService:OnInvoke(name, handler(player, ...) -> Result)
		RemoteService:FireClient(name, player, ...)
		RemoteService:FireClients(name, players, ...)
		RemoteService:FireAllClients(name, ...)
		RemoteService:ReportViolation(player, remoteName, reason)
		RemoteService:GetViolationCount(player) -> number
		RemoteService:VerifyHandlers()      -- Bootstrap, after all services started
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local NetworkConfig = require(Shared.Config.NetworkConfig)
local ResultCode = require(Shared.Constants.ResultCode)
local Result = require(Shared.Utilities.Result)
local Validate = require(Shared.Utilities.Validate)

local Server = script:FindFirstAncestor("Server") :: Instance
local RemoteRateLimiter = require(Server.Systems.RemoteRateLimiter)

local RemoteService = {}

local remotes: { [string]: Instance } = {}
local handlersBound: { [string]: boolean } = {}
local rateLimiter: any = nil
local violations: { [Player]: { number } } = {}

local function now(): number
	return os.clock()
end

function RemoteService:Init()
	local folder = ReplicatedStorage:FindFirstChild(NetworkConfig.FolderName)
	if folder then
		-- A stale folder (e.g. left in the place file) would shadow ours.
		folder:Destroy()
	end
	folder = Instance.new("Folder")
	folder.Name = NetworkConfig.FolderName

	local limits = {}
	for name, definition in NetworkConfig.Remotes do
		local remote = Instance.new(definition.Class)
		remote.Name = name
		remote.Parent = folder
		remotes[name] = remote
		if definition.RateLimit then
			limits[name] = definition.RateLimit
		end
	end
	folder.Parent = ReplicatedStorage

	rateLimiter = RemoteRateLimiter.new(limits)
end

function RemoteService:Start()
	Players.PlayerRemoving:Connect(function(player)
		rateLimiter:RemovePlayer(player)
		violations[player] = nil
	end)
end

-- Called by Bootstrap after every service has started. A client->server remote with
-- no handler would leave RemoteFunction calls hanging, so it is answered with a
-- failure and reported as a configuration error.
function RemoteService:VerifyHandlers()
	for name, definition in NetworkConfig.Remotes do
		if definition.Direction == "ClientToServer" and not handlersBound[name] then
			warn(`[RemoteService] no handler bound for {name}`)
			local remote = remotes[name]
			if remote:IsA("RemoteFunction") then
				(remote :: RemoteFunction).OnServerInvoke = function()
					return Result.Fail(ResultCode.ServerError)
				end
			end
		end
	end
end

function RemoteService:ReportViolation(player: Player, remoteName: string, reason: string)
	local list = violations[player]
	if list == nil then
		list = {}
		violations[player] = list
	end
	local t = now()
	table.insert(list, t)
	local window = NetworkConfig.Security.ViolationWindow
	while #list > 0 and t - list[1] > window do
		table.remove(list, 1)
	end
	if #list == NetworkConfig.Security.ViolationThreshold then
		warn(`[Security] {player.Name} ({player.UserId}) exceeded violation threshold; last: {remoteName} {reason}`)
		if NetworkConfig.Security.KickOnAbuse then
			player:Kick("Too many invalid requests.")
		end
	end
end

function RemoteService:GetViolationCount(player: Player): number
	local list = violations[player]
	return if list then #list else 0
end

-- Returns (ok, failureCode) for the shared guard pipeline.
local function guard(player: Player, name: string, argCount: number, args: { any }): (boolean, string?)
	if player.Parent ~= Players then
		return false, ResultCode.NotAllowed
	end
	if not rateLimiter:Check(player, name, now()) then
		RemoteService:ReportViolation(player, name, "rate limit")
		return false, ResultCode.RateLimited
	end
	local definition = NetworkConfig.Remotes[name]
	local ok, reason = Validate.CheckArgs(args, argCount, definition.Args or {})
	if not ok then
		RemoteService:ReportViolation(player, name, reason or "invalid")
		return false, ResultCode.InvalidPayload
	end
	return true, nil
end

local function getRemote(name: string, className: string): any
	local remote = remotes[name]
	assert(remote, `[RemoteService] unknown remote {name}`)
	assert(remote.ClassName == className, `[RemoteService] {name} is a {remote.ClassName}, not {className}`)
	return remote
end

function RemoteService:OnEvent(name: string, handler: (Player, ...any) -> ())
	local definition = NetworkConfig.Remotes[name]
	assert(definition and definition.Direction == "ClientToServer", `[RemoteService] {name} is not client->server`)
	assert(not handlersBound[name], `[RemoteService] handler for {name} bound twice`)
	handlersBound[name] = true

	local remote = getRemote(name, "RemoteEvent") :: RemoteEvent
	remote.OnServerEvent:Connect(function(player: Player, ...)
		local argCount = select("#", ...)
		local args = { ... }
		local ok = guard(player, name, argCount, args)
		if not ok then
			return
		end
		local success, err = xpcall(handler, debug.traceback, player, table.unpack(args, 1, argCount))
		if not success then
			warn(`[RemoteService] {name} handler error for {player.Name}: {err}`)
		end
	end)
end

function RemoteService:OnInvoke(name: string, handler: (Player, ...any) -> any)
	local definition = NetworkConfig.Remotes[name]
	assert(definition and definition.Direction == "ClientToServer", `[RemoteService] {name} is not client->server`)
	assert(not handlersBound[name], `[RemoteService] handler for {name} bound twice`)
	handlersBound[name] = true

	local remote = getRemote(name, "RemoteFunction") :: RemoteFunction
	remote.OnServerInvoke = function(player: Player, ...)
		local argCount = select("#", ...)
		local args = { ... }
		local ok, code = guard(player, name, argCount, args)
		if not ok then
			return Result.Fail(code :: string)
		end
		local success, response = xpcall(handler, debug.traceback, player, table.unpack(args, 1, argCount))
		if not success then
			warn(`[RemoteService] {name} handler error for {player.Name}: {response}`)
			return Result.Fail(ResultCode.ServerError)
		end
		if type(response) ~= "table" or type(response.Ok) ~= "boolean" then
			warn(`[RemoteService] {name} handler returned a non-Result value`)
			return Result.Fail(ResultCode.ServerError)
		end
		return response
	end
end

function RemoteService:FireClient(name: string, player: Player, ...: any)
	if player.Parent ~= Players then
		return
	end
	local remote = getRemote(name, "RemoteEvent") :: RemoteEvent
	remote:FireClient(player, ...)
end

function RemoteService:FireClients(name: string, players: { Player }, ...: any)
	local remote = getRemote(name, "RemoteEvent") :: RemoteEvent
	for _, player in players do
		if player.Parent == Players then
			remote:FireClient(player, ...)
		end
	end
end

function RemoteService:FireAllClients(name: string, ...: any)
	local remote = getRemote(name, "RemoteEvent") :: RemoteEvent
	remote:FireAllClients(...)
end

return RemoteService
