--!strict
-- Server-side character tracking:
--   * applies GameConfig.Health.MaxHealth to every spawned Humanoid
--   * registers collision groups and puts character parts in the Characters
--     group (client debris uses a group that never collides with it)
--   * keeps a cached record per player so other services can ask
--     "is this player alive, and where is their root?" without searching
--   * notifies listeners on spawn, death and despawn

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Utilities.Logger)
local ResourceCleanup = require(Shared.Utilities.ResourceCleanup)

export type CharacterRecord = {
	Character: Model,
	Humanoid: Humanoid,
	RootPart: BasePart,
	Alive: boolean,
	SpawnedAt: number,
}

type PlayerCallback = (player: Player) -> ()
type SpawnCallback = (player: Player, record: CharacterRecord) -> ()

local CHARACTER_PART_TIMEOUT = 10

local logger = Logger.new("CharacterService")

local CharacterService = {}

local records: { [Player]: CharacterRecord } = {}
local characterCleanups: { [Player]: ResourceCleanup.ResourceCleanup } = {}
local playerConnections: { [Player]: { RBXScriptConnection } } = {}
local spawnCallbacks: { SpawnCallback } = {}
local diedCallbacks: { PlayerCallback } = {}
local despawnCallbacks: { PlayerCallback } = {}
local started = false

local function notify<A...>(callbacks: { (A...) -> () }, ...: A...)
	for _, callback in callbacks do
		task.spawn(callback, ...)
	end
end

function CharacterService.OnSpawned(callback: SpawnCallback)
	table.insert(spawnCallbacks, callback)
end

function CharacterService.OnDied(callback: PlayerCallback)
	table.insert(diedCallbacks, callback)
end

function CharacterService.OnDespawned(callback: PlayerCallback)
	table.insert(despawnCallbacks, callback)
end

-- Current record, alive or not, if the character is still in the world.
function CharacterService.GetRecord(player: Player): CharacterRecord?
	local record = records[player]
	if record and record.Character.Parent ~= nil and record.RootPart.Parent ~= nil then
		return record
	end
	return nil
end

-- Record only if the character is alive and fully present.
function CharacterService.GetAliveRecord(player: Player): CharacterRecord?
	local record = CharacterService.GetRecord(player)
	if record and record.Alive and record.Humanoid.Health > 0 then
		return record
	end
	return nil
end

local function registerCollisionGroups()
	local groups = GameConfig.CollisionGroups
	for _, name in { groups.Characters, groups.VisualDebris } do
		if not PhysicsService:IsCollisionGroupRegistered(name) then
			PhysicsService:RegisterCollisionGroup(name)
		end
	end
	PhysicsService:CollisionGroupSetCollidable(groups.VisualDebris, groups.Characters, false)
	PhysicsService:CollisionGroupSetCollidable(groups.VisualDebris, groups.VisualDebris, false)
end

local function assignCollisionGroup(instance: Instance)
	if instance:IsA("BasePart") then
		instance.CollisionGroup = GameConfig.CollisionGroups.Characters
	end
end

local function despawn(player: Player)
	local cleanup = characterCleanups[player]
	characterCleanups[player] = nil
	local hadRecord = records[player] ~= nil
	records[player] = nil
	if cleanup then
		cleanup:Destroy()
	end
	if hadRecord then
		notify(despawnCallbacks, player)
	end
end

local function onCharacterAdded(player: Player, character: Model)
	despawn(player)
	local cleanup = ResourceCleanup.new(`Character:{player.UserId}`)
	characterCleanups[player] = cleanup

	local humanoid = character:WaitForChild("Humanoid", CHARACTER_PART_TIMEOUT)
	local rootPart = character:WaitForChild("HumanoidRootPart", CHARACTER_PART_TIMEOUT)
	if player.Character ~= character or cleanup:IsDestroyed() then
		return -- respawned or left while waiting
	end
	if not (humanoid and humanoid:IsA("Humanoid")) or not (rootPart and rootPart:IsA("BasePart")) then
		logger:Warn("CharacterIncomplete", { UserId = player.UserId, Character = character })
		return
	end

	humanoid.MaxHealth = GameConfig.Health.MaxHealth
	humanoid.Health = GameConfig.Health.MaxHealth

	for _, descendant in character:GetDescendants() do
		assignCollisionGroup(descendant)
	end
	cleanup:Connect(character.DescendantAdded, assignCollisionGroup)

	local record: CharacterRecord = {
		Character = character,
		Humanoid = humanoid,
		RootPart = rootPart,
		Alive = true,
		SpawnedAt = os.clock(),
	}
	records[player] = record

	cleanup:Connect(humanoid.Died, function()
		record.Alive = false
		notify(diedCallbacks, player)
	end)

	notify(spawnCallbacks, player, record)
end

local function onPlayerAdded(player: Player)
	if playerConnections[player] then
		return
	end
	playerConnections[player] = {
		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end),
		player.CharacterRemoving:Connect(function(character)
			if records[player] and records[player].Character == character then
				despawn(player)
			end
		end),
	}
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	despawn(player)
	local connections = playerConnections[player]
	playerConnections[player] = nil
	if connections then
		for _, connection in connections do
			connection:Disconnect()
		end
	end
end

function CharacterService.Start()
	assert(not started, "CharacterService already started")
	started = true
	registerCollisionGroups()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return CharacterService
