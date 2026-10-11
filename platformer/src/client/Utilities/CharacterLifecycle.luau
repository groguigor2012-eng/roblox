--!strict
-- Central character lifecycle for the local player. Controllers register
-- handlers once; the lifecycle calls them for every spawn, death and
-- despawn, and gives each spawn a fresh Context whose Cleanup is destroyed
-- when that character goes away. Anything a controller adds to
-- context.Cleanup (connections, constraints, effects, threads) therefore
-- cannot outlive its character or affect the next one.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Logger = require(Shared:WaitForChild("Utilities"):WaitForChild("Logger"))
local ResourceCleanup = require(Shared:WaitForChild("Utilities"):WaitForChild("ResourceCleanup"))

export type Context = {
	Character: Model,
	Humanoid: Humanoid,
	RootPart: BasePart,
	-- Destroyed on despawn; add per-character resources here.
	Cleanup: ResourceCleanup.ResourceCleanup,
	Alive: boolean,
	-- Increments per spawn; lets async work detect it belongs to an old character.
	Generation: number,
}

export type Handler = {
	OnSpawn: (context: Context) -> (),
	OnDied: ((context: Context) -> ())?,
	OnDespawn: ((context: Context) -> ())?,
}

local PART_TIMEOUT = 10

local logger = Logger.new("CharacterLifecycle")

local CharacterLifecycle = {}

local handlers: { { Name: string, Handler: Handler } } = {}
local current: Context? = nil
local generation = 0
local started = false

local function traceback(err: any): string
	return debug.traceback(tostring(err), 2)
end

local function invoke(name: string, phase: string, callback: (Context) -> (), context: Context)
	local ok, err = xpcall(function(): string?
		callback(context)
		return nil
	end, traceback)
	if not ok then
		logger:Error("HandlerFailed", { Handler = name, Phase = phase, Error = err })
	end
end

local function despawn()
	local context = current
	if not context then
		return
	end
	current = nil
	context.Alive = false
	for _, entry in handlers do
		if entry.Handler.OnDespawn then
			invoke(entry.Name, "OnDespawn", entry.Handler.OnDespawn, context)
		end
	end
	context.Cleanup:Destroy()
end

local function spawnCharacter(character: Model)
	despawn()
	generation += 1
	local myGeneration = generation

	local humanoid = character:WaitForChild("Humanoid", PART_TIMEOUT)
	local rootPart = character:WaitForChild("HumanoidRootPart", PART_TIMEOUT)
	if myGeneration ~= generation or character.Parent == nil then
		return -- replaced or removed while waiting
	end
	if not (humanoid and humanoid:IsA("Humanoid")) or not (rootPart and rootPart:IsA("BasePart")) then
		logger:Warn("CharacterIncomplete", { Character = character })
		return
	end

	local context: Context = {
		Character = character,
		Humanoid = humanoid,
		RootPart = rootPart,
		Cleanup = ResourceCleanup.new(`LocalCharacter#{myGeneration}`),
		Alive = humanoid.Health > 0,
		Generation = myGeneration,
	}
	current = context

	context.Cleanup:Connect(humanoid.Died, function()
		if not context.Alive then
			return
		end
		context.Alive = false
		for _, entry in handlers do
			if entry.Handler.OnDied then
				invoke(entry.Name, "OnDied", entry.Handler.OnDied, context)
			end
		end
	end)
	context.Cleanup:Connect(character.AncestryChanged, function()
		if current == context and not character:IsDescendantOf(game) then
			despawn()
		end
	end)

	for _, entry in handlers do
		invoke(entry.Name, "OnSpawn", entry.Handler.OnSpawn, context)
	end
end

-- Registers a handler. If a character already exists it receives OnSpawn now.
function CharacterLifecycle.Register(name: string, handler: Handler)
	for _, entry in handlers do
		assert(entry.Name ~= name, `CharacterLifecycle handler "{name}" registered twice`)
	end
	table.insert(handlers, { Name = name, Handler = handler })
	if current then
		invoke(name, "OnSpawn", handler.OnSpawn, current)
	end
end

function CharacterLifecycle.GetContext(): Context?
	return current
end

function CharacterLifecycle.Start()
	assert(not started, "CharacterLifecycle already started")
	started = true
	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(spawnCharacter)
	player.CharacterRemoving:Connect(function(character: Model)
		if current and current.Character == character then
			despawn()
		end
	end)
	if player.Character then
		task.spawn(spawnCharacter, player.Character)
	end
end

return CharacterLifecycle
