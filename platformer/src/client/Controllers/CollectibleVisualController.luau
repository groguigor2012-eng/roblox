--!strict
-- Client half of the collectible system: presentation, per-player
-- visibility and pickup requests for every "Collectible"-tagged instance.
--
-- Registration follows CollectionService on the client, which also covers
-- StreamingEnabled: an item streaming in fires the added signal and an item
-- streaming out fires the removed signal, so no stale references are kept.
--
-- One PreRender connection animates all visible items within
-- Visual.AnimationRadius of the camera with a single BulkMoveTo call, and
-- checks pickup proximity every Collection.ClientCheckInterval. Spinning is
-- local only (the server never moves these parts), so it costs no
-- replication. The work scales with registered (streamed-in) items, never
-- with the whole Workspace.
--
-- Visibility: an item is hidden for this player when it is Shared and the
-- server marked it unavailable, when its stable id is in the collected set
-- (sent by the server on join and updated by pickups), or when this player
-- collected an id-less item this session. Hiding uses
-- LocalTransparencyModifier/Enabled, so nothing changes for other players.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local CollectibleConfig = require(Config:WaitForChild("CollectibleConfig"))
local GameConfig = require(Config:WaitForChild("GameConfig"))
local ResourceCleanup = require(Shared:WaitForChild("Utilities"):WaitForChild("ResourceCleanup"))
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent.Parent
local CharacterLifecycle = require(Client.Utilities.CharacterLifecycle)
local Effects = require(Client.Utilities.Effects)
local AudioController = require(script.Parent.AudioController)

type Visual = {
	Instance: PVInstance,
	IsPart: boolean,
	BasePosition: Vector3,
	BaseRotation: CFrame,
	Extent: number,
	Phase: number,
	StableId: string?,
	IsShared: boolean,
	Unavailable: boolean,
	CollectedLocally: boolean,
	Hidden: boolean,
	PendingUntil: number,
	RetryAt: number,
	SavedEnabled: { [Instance]: boolean },
	Cleanup: ResourceCleanup.ResourceCleanup,
}

local TAG = GameConfig.Tags.Collectible
local ATTR = CollectibleConfig.Attributes
local VisualConfig = CollectibleConfig.Visual
local Collection = CollectibleConfig.Collection

local CollectibleVisualController = {}

local visuals: { [Instance]: Visual } = {}
local collectedIds: { [string]: boolean } = {}
-- Id-less items this player collected this session (weak: destroyed items can be collected).
local collectedInstances: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local remotes: Types.Remotes? = nil
local animatedParts: { BasePart } = {}
local animatedCFrames: { CFrame } = {}
local proximityAccumulator = 0
local random = Random.new()
local started = false

local function applyHidden(visual: Visual, item: Instance, hidden: boolean)
	if item:IsA("BasePart") or item:IsA("Decal") then
		(item :: any).LocalTransparencyModifier = if hidden then 1 else 0
	elseif
		item:IsA("ParticleEmitter")
		or item:IsA("Light")
		or item:IsA("BillboardGui")
		or item:IsA("SurfaceGui")
		or item:IsA("Beam")
		or item:IsA("Trail")
	then
		local toggle = item :: any
		if hidden then
			if visual.SavedEnabled[item] == nil then
				visual.SavedEnabled[item] = toggle.Enabled
			end
			toggle.Enabled = false
		else
			local saved = visual.SavedEnabled[item]
			if saved ~= nil then
				toggle.Enabled = saved
			end
		end
	end
end

local function setHidden(visual: Visual, hidden: boolean)
	if visual.Hidden == hidden then
		return
	end
	visual.Hidden = hidden
	applyHidden(visual, visual.Instance, hidden)
	for _, descendant in visual.Instance:GetDescendants() do
		applyHidden(visual, descendant, hidden)
	end
	if not hidden then
		table.clear(visual.SavedEnabled)
	end
end

local function refreshVisibility(visual: Visual)
	local collected = if visual.IsShared
		then false
		else visual.CollectedLocally or (visual.StableId ~= nil and collectedIds[visual.StableId] == true)
	setHidden(visual, visual.Unavailable or collected)
end

local function readAttributes(visual: Visual)
	local instance = visual.Instance
	local id = instance:GetAttribute(ATTR.Id)
	visual.StableId = if type(id) == "string" and id ~= "" then id else nil
	visual.IsShared = instance:GetAttribute(ATTR.Mode) == "Shared"
	visual.Unavailable = visual.IsShared and instance:GetAttribute(ATTR.Available) == false
end

local function register(instance: Instance)
	if visuals[instance] or not (instance:IsA("BasePart") or instance:IsA("Model")) then
		return
	end
	local pvInstance = instance :: PVInstance
	local pivot = pvInstance:GetPivot()
	local size = if instance:IsA("BasePart") then instance.Size else (instance :: Model):GetExtentsSize()
	local visual: Visual = {
		Instance = pvInstance,
		IsPart = instance:IsA("BasePart"),
		BasePosition = pivot.Position,
		BaseRotation = pivot.Rotation,
		Extent = math.max(size.X, size.Y, size.Z) / 2,
		Phase = random:NextNumber(0, math.pi * 2),
		StableId = nil,
		IsShared = false,
		Unavailable = false,
		CollectedLocally = collectedInstances[instance] == true,
		Hidden = false,
		PendingUntil = 0,
		RetryAt = 0,
		SavedEnabled = {},
		Cleanup = ResourceCleanup.new(`CollectibleVisual:{instance.Name}`),
	}
	readAttributes(visual)
	visuals[instance] = visual

	visual.Cleanup:Connect(instance.AttributeChanged, function(attribute: string)
		if attribute == ATTR.Available or attribute == ATTR.Id or attribute == ATTR.Mode then
			readAttributes(visual)
			refreshVisibility(visual)
		end
	end)
	-- Parts of a non-atomic model can stream in after the model itself.
	visual.Cleanup:Connect(instance.DescendantAdded, function(descendant: Instance)
		if visual.Hidden then
			applyHidden(visual, descendant, true)
		end
	end)
	refreshVisibility(visual)
end

local function unregister(instance: Instance)
	local visual = visuals[instance]
	if not visual then
		return
	end
	visuals[instance] = nil
	visual.Cleanup:Destroy()
	if instance.Parent ~= nil then
		-- Tag removed but the instance stays: restore its pose and visibility.
		setHidden(visual, false)
		visual.Instance:PivotTo(CFrame.new(visual.BasePosition) * visual.BaseRotation)
	end
end

local function markCollected(visual: Visual)
	if visual.IsShared then
		return
	end
	if visual.StableId then
		collectedIds[visual.StableId] = true
	else
		visual.CollectedLocally = true
		collectedInstances[visual.Instance] = true
	end
end

local function playPickup(visual: Visual, result: Types.CollectResult)
	local position = visual.Instance:GetPivot().Position
	local currency: Types.CurrencyType? = result.CurrencyType
	local color = if currency then VisualConfig.Colors[currency] else Color3.new(1, 1, 1)
	Effects.PickupGhost(visual.Instance)
	Effects.PickupBurst(position, color)
	if currency then
		-- Only reached from a server-confirmed CollectResult.
		AudioController.PlayCollect(currency)
	end
	if VisualConfig.FloatingText and currency and result.Amount then
		local name = VisualConfig.DisplayNames[currency]
		local label = if result.Amount == 1 then name else name .. "s"
		Effects.FloatingText(position + Vector3.new(0, 1.5, 0), `+{result.Amount} {label}`, color)
	end
end

local function onCollectResult(result: any)
	if type(result) ~= "table" then
		return
	end
	local instance = result.Instance
	local visual = if typeof(instance) == "Instance" then visuals[instance] else nil
	if result.Success == true then
		if type(result.CollectibleId) == "string" and not (visual and visual.IsShared) then
			collectedIds[result.CollectibleId] = true
		end
		if visual then
			visual.PendingUntil = 0
			markCollected(visual)
			playPickup(visual, result :: Types.CollectResult)
			if visual.IsShared then
				visual.Unavailable = true -- the server's Available=false is on its way
			end
			refreshVisibility(visual)
		end
		return
	end
	if not visual then
		return
	end
	visual.PendingUntil = 0
	if result.Reason == "AlreadyCollected" then
		markCollected(visual)
		refreshVisibility(visual)
	else
		visual.RetryAt = os.clock() + Collection.RetryCooldown
	end
end

local function onCollectionState(state: any)
	if type(state) ~= "table" or type(state.CollectedIds) ~= "table" then
		return
	end
	for _, id in state.CollectedIds do
		if type(id) == "string" then
			collectedIds[id] = true
		end
	end
	for instance in visuals do
		refreshVisibility(visuals[instance])
	end
end

local function checkProximity(now: number)
	local context = CharacterLifecycle.GetContext()
	if not context or not context.Alive then
		return
	end
	local rootPosition = context.RootPart.Position
	local remoteTable = remotes :: Types.Remotes
	for instance, visual in visuals do
		if visual.Hidden or now < visual.PendingUntil or now < visual.RetryAt then
			continue
		end
		local reach = Collection.ClientCollectRadius + visual.Extent
		local offset = visual.BasePosition - rootPosition
		if offset:Dot(offset) <= reach * reach then
			visual.PendingUntil = now + Collection.RequestTimeout
			remoteTable.CollectRequest:FireServer(instance)
		end
	end
end

local function onPreRender(deltaTime: number)
	local now = os.clock()
	proximityAccumulator += deltaTime
	if proximityAccumulator >= Collection.ClientCheckInterval then
		proximityAccumulator = 0
		checkProximity(now)
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local cameraPosition = camera.CFrame.Position
	local radiusSquared = VisualConfig.AnimationRadius * VisualConfig.AnimationRadius
	local spin = math.rad(VisualConfig.SpinDegreesPerSecond) * now
	local bobFrequency = (math.pi * 2) / VisualConfig.BobPeriod

	table.clear(animatedParts)
	table.clear(animatedCFrames)
	for instance, visual in visuals do
		if visual.Hidden then
			continue
		end
		local offset = visual.BasePosition - cameraPosition
		if offset:Dot(offset) > radiusSquared then
			continue
		end
		local bob = math.sin(now * bobFrequency + visual.Phase) * VisualConfig.BobHeight
		local cframe = CFrame.new(visual.BasePosition + Vector3.new(0, bob, 0))
			* CFrame.Angles(0, spin + visual.Phase, 0)
			* visual.BaseRotation
		if visual.IsPart then
			table.insert(animatedParts, instance :: BasePart)
			table.insert(animatedCFrames, cframe)
		else
			(instance :: Model):PivotTo(cframe)
		end
	end
	if #animatedParts > 0 then
		Workspace:BulkMoveTo(animatedParts, animatedCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function CollectibleVisualController.Init(remoteTable: Types.Remotes)
	remotes = remoteTable
end

function CollectibleVisualController.Start()
	assert(not started, "CollectibleVisualController already started")
	assert(remotes, "CollectibleVisualController.Init must run before Start")
	started = true
	local remoteTable = remotes :: Types.Remotes

	remoteTable.CollectionState.OnClientEvent:Connect(onCollectionState)
	remoteTable.CollectResult.OnClientEvent:Connect(onCollectResult)

	CollectionService:GetInstanceAddedSignal(TAG):Connect(register)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unregister)
	for _, instance in CollectionService:GetTagged(TAG) do
		register(instance)
	end

	RunService.PreRender:Connect(onPreRender)
end

return CollectibleVisualController
