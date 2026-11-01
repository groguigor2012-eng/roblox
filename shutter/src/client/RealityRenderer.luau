--!strict
-- RealityRenderer (client): the Dual-Reality layer swap.
--
--   CameraOnly    -> drawn only while the server says this player is filming
--   NakedEyeOnly  -> drawn only while NOT filming
--
-- A tag covers the tagged instance and all its descendants. If a descendant sits under both
-- kinds of tag, the nearest tagged ancestor wins (so a NakedEyeOnly wall can live inside a
-- ShutterDoor model next to a CameraOnly door).
--
-- How each class is hidden locally (nothing here replicates):
--   BasePart                            LocalTransparencyModifier = 1
--   Decal / Texture                     Transparency = 1
--   Light, ParticleEmitter, Beam, Trail, Fire, Smoke, Sparkles, Highlight,
--   BillboardGui, SurfaceGui, ProximityPrompt                   Enabled = false
--   Sound                               Volume = 0
-- If the server later changes one of those properties, the new value is adopted as the
-- "real" value and the layer is re-applied, so server changes are never lost.
--
-- Security note: hiding is cosmetic. Anything that matters (prompt use, freezing the Watcher)
-- is validated on the server against the server's camcorder state.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shutter"):WaitForChild("Config"))

local TAGS = Config.Tags

type Layer = "Camera" | "Naked"

type Entry = {
	instance: Instance,
	layer: Layer,
	property: string,
	hiddenValue: any,
	original: any,
	applying: boolean,
	connections: { RBXScriptConnection },
}

local RealityRenderer = {}

local entries: { [Instance]: Entry } = {}
local rootConnections: { [Instance]: { RBXScriptConnection } } = {}
local filming = false
local started = false

local ENABLED_CLASSES = {
	"Light",
	"ParticleEmitter",
	"Beam",
	"Trail",
	"Fire",
	"Smoke",
	"Sparkles",
	"Highlight",
	"BillboardGui",
	"SurfaceGui",
	"ProximityPrompt",
}

local function controlFor(instance: Instance): (string?, any)
	if instance:IsA("BasePart") then
		return "LocalTransparencyModifier", 1
	elseif instance:IsA("Decal") then -- includes Texture
		return "Transparency", 1
	elseif instance:IsA("Sound") then
		return "Volume", 0
	end
	for _, className in ENABLED_CLASSES do
		if instance:IsA(className) then
			return "Enabled", false
		end
	end
	return nil, nil
end

local function layerOf(instance: Instance): Layer?
	local current: Instance? = instance
	while current and current ~= game do
		if CollectionService:HasTag(current, TAGS.CameraOnly) then
			return "Camera"
		elseif CollectionService:HasTag(current, TAGS.NakedEyeOnly) then
			return "Naked"
		end
		current = current.Parent
	end
	return nil
end

local function shouldShow(layer: Layer): boolean
	return if layer == "Camera" then filming else not filming
end

local function write(entry: Entry, value: any)
	local target = entry.instance :: any
	if target[entry.property] == value then
		return
	end
	entry.applying = true
	target[entry.property] = value
	entry.applying = false
end

local function apply(entry: Entry)
	if shouldShow(entry.layer) then
		-- LocalTransparencyModifier has no "original": visible is always 0.
		write(entry, if entry.property == "LocalTransparencyModifier" then 0 else entry.original)
	else
		write(entry, entry.hiddenValue)
	end
end

local function unregister(instance: Instance)
	local entry = entries[instance]
	if not entry then
		return
	end
	entries[instance] = nil
	for _, connection in entry.connections do
		connection:Disconnect()
	end
	if instance.Parent then
		-- Leave it as the server intends: visible.
		write(entry, if entry.property == "LocalTransparencyModifier" then 0 else entry.original)
	end
end

local function register(instance: Instance)
	local layer = layerOf(instance)
	local existing = entries[instance]
	if not layer then
		if existing then
			unregister(instance)
		end
		return
	end
	if existing then
		existing.layer = layer
		apply(existing)
		return
	end
	local property, hiddenValue = controlFor(instance)
	if not property then
		return
	end
	local entry: Entry = {
		instance = instance,
		layer = layer,
		property = property,
		hiddenValue = hiddenValue,
		original = (instance :: any)[property],
		applying = false,
		connections = {},
	}
	entries[instance] = entry

	if property ~= "LocalTransparencyModifier" then
		table.insert(
			entry.connections,
			instance:GetPropertyChangedSignal(property):Connect(function()
				if entry.applying then
					return
				end
				-- Changed by the server (or another script): that is the new real value.
				entry.original = (instance :: any)[property]
				apply(entry)
			end)
		)
	end
	table.insert(
		entry.connections,
		instance.AncestryChanged:Connect(function()
			if not instance:IsDescendantOf(game) then
				unregister(instance)
			else
				register(instance) -- re-parented: its layer may have changed
			end
		end)
	)
	apply(entry)
end

local function registerTree(root: Instance)
	register(root)
	for _, descendant in root:GetDescendants() do
		register(descendant)
	end
end

local function onTagged(root: Instance)
	registerTree(root)
	if rootConnections[root] then
		return
	end
	rootConnections[root] = {
		root.DescendantAdded:Connect(register),
	}
end

local function onUntagged(root: Instance)
	-- Recompute: descendants may now belong to another layer or to none.
	if not CollectionService:HasTag(root, TAGS.CameraOnly) and not CollectionService:HasTag(root, TAGS.NakedEyeOnly) then
		local connections = rootConnections[root]
		if connections then
			for _, connection in connections do
				connection:Disconnect()
			end
			rootConnections[root] = nil
		end
	end
	registerTree(root)
end

function RealityRenderer.start()
	if started then
		return
	end
	started = true
	for _, tag in { TAGS.CameraOnly, TAGS.NakedEyeOnly } do
		CollectionService:GetInstanceAddedSignal(tag):Connect(onTagged)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(onUntagged)
		for _, instance in CollectionService:GetTagged(tag) do
			onTagged(instance)
		end
	end
end

function RealityRenderer.setFilming(isFilming: boolean)
	if filming == isFilming then
		return
	end
	filming = isFilming
	for _, entry in entries do
		apply(entry)
	end
end

function RealityRenderer.isFilming(): boolean
	return filming
end

return RealityRenderer
