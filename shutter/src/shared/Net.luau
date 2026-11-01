--!strict
-- Single access point for THE SHUTTER's remotes.
-- Server: finds each remote in ReplicatedStorage > Shutter > Remotes, creating any that
--         are missing (so a hand-built place still works).
-- Client: waits for the server-created remotes.

local RunService = game:GetService("RunService")

local Config = require(script.Parent:WaitForChild("Config"))

local IS_SERVER = RunService:IsServer()
local CLIENT_TIMEOUT = 30

local function getFolder(): Folder
	local root = script.Parent
	if IS_SERVER then
		local existing = root:FindFirstChild("Remotes")
		if existing and existing:IsA("Folder") then
			return existing
		end
		local folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = root
		return folder
	end
	local found = root:WaitForChild("Remotes", CLIENT_TIMEOUT)
	assert(found and found:IsA("Folder"), "[Shutter] ReplicatedStorage.Shutter.Remotes is missing")
	return found
end

local folder = getFolder()

local function getRemote(name: string, className: string): Instance
	if IS_SERVER then
		local existing = folder:FindFirstChild(name)
		if existing and existing.ClassName == className then
			return existing
		end
		if existing then
			warn(`[Shutter] Remote {name} is a {existing.ClassName}, expected {className}; replacing it`)
			existing:Destroy()
		end
		local remote = Instance.new(className)
		remote.Name = name
		remote.Parent = folder
		return remote
	end
	local found = folder:WaitForChild(name, CLIENT_TIMEOUT)
	assert(found and found.ClassName == className, `[Shutter] Remote {name} ({className}) is missing`)
	return found
end

local Net = {
	CamcorderToggle = getRemote(Config.Remotes.CamcorderToggle, "RemoteEvent") :: RemoteEvent,
	SprintState = getRemote(Config.Remotes.SprintState, "RemoteEvent") :: RemoteEvent,
	LookUpdate = getRemote(Config.Remotes.LookUpdate, "UnreliableRemoteEvent") :: UnreliableRemoteEvent,
	WatcherFeedback = getRemote(Config.Remotes.WatcherFeedback, "RemoteEvent") :: RemoteEvent,
}

return Net
