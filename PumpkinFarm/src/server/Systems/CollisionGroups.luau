--!strict
--[[
	CollisionGroups
	Path: ServerScriptService.Server.Systems.CollisionGroups

	Registers the game's collision groups once and provides helpers to assign a whole
	model to a group. Matrix:

		              Default  Players  Enemies  Defenses  Ghost
		Default         yes      yes      yes      yes      no
		Players         yes      yes      yes      no       no
		Enemies         yes      yes      no       yes      no
		Defenses        yes      no       yes      no       no
		Ghost           no       no       no       no       no

	Dependencies: Shared.Constants.CollisionGroup

	API:
		CollisionGroups.Setup()
		CollisionGroups.SetModel(model, groupName)
		CollisionGroups.SetPart(part, groupName)
]]

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CollisionGroup = require(ReplicatedStorage.Shared.Constants.CollisionGroup)

local CollisionGroups = {}

local initialized = false

local function register(name: string)
	if not PhysicsService:IsCollisionGroupRegistered(name) then
		PhysicsService:RegisterCollisionGroup(name)
	end
end

function CollisionGroups.Setup()
	if initialized then
		return
	end
	initialized = true

	for _, name in CollisionGroup do
		register(name)
	end

	local players, enemies, defenses, ghost =
		CollisionGroup.Players, CollisionGroup.Enemies, CollisionGroup.Defenses, CollisionGroup.Ghost

	PhysicsService:CollisionGroupSetCollidable(enemies, enemies, false)
	PhysicsService:CollisionGroupSetCollidable(players, defenses, false)
	PhysicsService:CollisionGroupSetCollidable(defenses, defenses, false)

	for _, other in { "Default", players, enemies, defenses, ghost } do
		PhysicsService:CollisionGroupSetCollidable(ghost, other, false)
	end
end

function CollisionGroups.SetPart(part: BasePart, groupName: string)
	part.CollisionGroup = groupName
end

function CollisionGroups.SetModel(model: Instance, groupName: string)
	if model:IsA("BasePart") then
		model.CollisionGroup = groupName
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = groupName
		end
	end
end

return CollisionGroups
