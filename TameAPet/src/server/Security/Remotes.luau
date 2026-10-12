-- Server-side access to the fixed set of remotes in ReplicatedStorage.Remotes. Creates any
-- that are missing (so the place works without Rojo) and replaces ones of the wrong class.
-- Only names from Shared.RemoteNames are ever created or looked up.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteNames = require(ReplicatedStorage.Shared.RemoteNames)

local Remotes = {}

local cache: { [string]: Instance } = {}

function Remotes.ensure()
	local folder = ReplicatedStorage:FindFirstChild(RemoteNames.FolderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = RemoteNames.FolderName
		folder.Parent = ReplicatedStorage
	end
	for _, spec in RemoteNames.List do
		local existing = folder:FindFirstChild(spec.name)
		if existing and existing.ClassName ~= spec.className then
			warn(`[Remotes] {spec.name} is a {existing.ClassName}, expected {spec.className}; replacing it`)
			existing:Destroy()
			existing = nil
		end
		if not existing then
			existing = Instance.new(spec.className)
			existing.Name = spec.name
			existing.Parent = folder
		end
		cache[spec.name] = existing
	end
end

function Remotes.get(name: string): any
	local remote = cache[name]
	if not remote then
		error(`[Remotes] Unknown remote "{name}" (call Remotes.ensure() first and add it to Shared.RemoteNames)`)
	end
	return remote
end

function Remotes.fire(name: string, player: Player, ...: any)
	if player.Parent == nil then
		return
	end
	Remotes.get(name):FireClient(player, ...)
end

function Remotes.fireAll(name: string, ...: any)
	Remotes.get(name):FireAllClients(...)
end

return Remotes
