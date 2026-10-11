--!strict
-- Creates (or verifies) every remote in GameConfig.Remotes under
-- ReplicatedStorage.Shared.Remotes. The folder is parented last, so a client
-- that sees the folder sees all remotes inside it. A pre-existing instance
-- with the right name but the wrong class is a hard error: a mismatched
-- remote contract is a security bug, not something to work around.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Utilities.Logger)
local Types = require(Shared.Types)

local logger = Logger.new("RemoteRegistry")

local RemoteRegistry = {}

local created: Types.Remotes? = nil

function RemoteRegistry.Create(): Types.Remotes
	if created then
		return created
	end

	local folderName = GameConfig.Folders.Remotes
	local existing = Shared:FindFirstChild(folderName)
	if existing and not existing:IsA("Folder") then
		error(`ReplicatedStorage.Shared.{folderName} exists but is a {existing.ClassName}, expected Folder`)
	end
	local folder = (existing or Instance.new("Folder")) :: Folder
	folder.Name = folderName

	local remotes: { [string]: RemoteEvent } = {}
	for name, className in GameConfig.Remotes do
		if className ~= "RemoteEvent" then
			error(`Remote {name}: unsupported class {className}`)
		end
		local remote = folder:FindFirstChild(name)
		if remote then
			if not remote:IsA("RemoteEvent") then
				error(`Remote {name} exists as {remote.ClassName}, expected {className}`)
			end
		else
			local newRemote = Instance.new("RemoteEvent")
			newRemote.Name = name
			newRemote.Parent = folder
			remote = newRemote
		end
		remotes[name] = remote :: RemoteEvent
	end

	for _, child in folder:GetChildren() do
		if GameConfig.Remotes[child.Name] == nil then
			logger:Warn("UnknownRemote", { Name = child.Name, Class = child.ClassName })
		end
	end

	folder.Parent = Shared
	local result = (remotes :: any) :: Types.Remotes
	created = result
	return result
end

return RemoteRegistry
