--!strict
--[[
	Net
	Path: StarterPlayerScripts.Client.Modules.Net

	Client side of the remote layer. Remote instances are created by the server's
	RemoteService under ReplicatedStorage.Remotes from NetworkConfig; this module only
	looks them up by name. Invoke never throws: transport errors become a failed Result
	so UI code can always handle { Ok, Code, Data }.

	The client sends INTENT only. Nothing returned here is trusted by the server.

	API:
		Net:Invoke(name, ...) -> Result        (yields)
		Net:Fire(name, ...)
		Net:On(name, handler) -> RBXScriptConnection
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NetworkConfig = require(Shared:WaitForChild("Config"):WaitForChild("NetworkConfig"))
local ResultCode = require(Shared:WaitForChild("Constants"):WaitForChild("ResultCode"))

local Net = {}

local folder = ReplicatedStorage:WaitForChild(NetworkConfig.FolderName)
local cache: { [string]: Instance } = {}

local function getRemote(name: string): Instance
	local remote = cache[name]
	if remote then
		return remote
	end
	assert(NetworkConfig.Remotes[name], `[Net] unknown remote {name}`)
	local found = folder:WaitForChild(name, 30)
	assert(found, `[Net] remote {name} did not replicate`)
	cache[name] = found
	return found
end

function Net:Invoke(name: string, ...: any): { Ok: boolean, Code: string, Data: any? }
	local remote = getRemote(name) :: RemoteFunction
	local ok, result = pcall(remote.InvokeServer, remote, ...)
	if not ok or type(result) ~= "table" then
		return { Ok = false, Code = ResultCode.ServerError }
	end
	return result
end

function Net:Fire(name: string, ...: any)
	local remote = getRemote(name) :: RemoteEvent
	remote:FireServer(...)
end

function Net:On(name: string, handler: (...any) -> ()): RBXScriptConnection
	local remote = getRemote(name) :: RemoteEvent
	return remote.OnClientEvent:Connect(handler)
end

return Net
