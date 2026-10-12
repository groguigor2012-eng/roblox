-- Client access to the fixed set of remotes (names from Shared.RemoteNames).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteNames = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RemoteNames"))

local Net = {}

export type Result = { ok: boolean, code: string, message: string?, data: any? }

local folder: Instance
local cache: { [string]: Instance } = {}

local function remote(name: string): any
	local cached = cache[name]
	if cached then
		return cached
	end
	local found = folder:WaitForChild(name, 15)
	if not found then
		error(`[Net] Remote "{name}" did not appear in ReplicatedStorage.{RemoteNames.FolderName}`)
	end
	cache[name] = found
	return found
end

-- Calls a request remote. Never throws; network failures become a Result.
function Net.invoke(name: string, ...: any): Result
	local args = table.pack(...)
	local ok, result = pcall(function()
		return remote(name):InvokeServer(table.unpack(args, 1, args.n))
	end)
	if not ok then
		warn(`[Net] {name} failed: {result}`)
		return { ok = false, code = "NetworkError", message = "Connection problem. Try again." }
	end
	if type(result) ~= "table" then
		return { ok = false, code = "ServerError", message = "Unexpected response from the server." }
	end
	return result
end

function Net.fire(name: string, ...: any)
	remote(name):FireServer(...)
end

function Net.on(name: string, handler: (...any) -> ()): RBXScriptConnection
	return remote(name).OnClientEvent:Connect(handler)
end

function Net.init()
	folder = ReplicatedStorage:WaitForChild(RemoteNames.FolderName)
end

function Net.start() end

return Net
