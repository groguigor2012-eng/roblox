--!strict
-- InteractionService (server): ProximityPrompts that live inside CameraOnly objects.
--
-- Clients only SEE these prompts while filming (RealityRenderer hides them otherwise), but a
-- hidden prompt can still be fired by an exploiter. So every trigger is re-checked here:
--   1. the player is filming (server camcorder state, battery > 0)
--   2. head-to-object distance <= prompt.MaxActivationDistance + slack
--   3. the player's view points roughly at the object (server-stamped look direction)
--   4. nothing solid is between the head and the object (server raycast)
--
-- Built-in behaviours:
--   ShutterDoor   (Model/Part) - every BasePart inside stops colliding and fades out.
--   ShutterPickup (Model/Part) - Attribute PickupKind = "Clue" | "Battery" (+ optional Amount).
-- Other systems can subscribe with InteractionService.onInteracted(callback).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shutter")
local Config = require(Shared:WaitForChild("Config"))
local CamcorderService = require(script.Parent:WaitForChild("CamcorderService"))

local TAGS = Config.Tags
local INTERACT = Config.Interaction
local ATTR = Config.Attributes

type InteractedCallback = (player: Player, target: Instance, prompt: ProximityPrompt) -> ()

local InteractionService = {}

local callbacks: { InteractedCallback } = {}
local hookedPrompts: { [ProximityPrompt]: RBXScriptConnection } = {}
local lastUse: { [Player]: { [ProximityPrompt]: number } } = {}
local started = false

local function findTaggedAncestor(instance: Instance, tag: string): Instance?
	local current: Instance? = instance
	while current and current ~= workspace do
		if CollectionService:HasTag(current, tag) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function worldPosition(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	elseif instance:IsA("Attachment") then
		return instance.WorldPosition
	elseif instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	local parent = instance.Parent
	return if parent then worldPosition(parent) else nil
end

local function hasLineOfSight(player: Player, origin: Vector3, target: Vector3, targetObject: Instance): boolean
	local exclude: { Instance } = { targetObject }
	if player.Character then
		table.insert(exclude, player.Character)
	end
	-- NakedEyeOnly parts are hidden while filming, so they must not block the camcorder.
	for _, hidden in CollectionService:GetTagged(TAGS.NakedEyeOnly) do
		table.insert(exclude, hidden)
	end
	for _, entity in CollectionService:GetTagged(TAGS.Entity) do
		table.insert(exclude, entity)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true

	local direction = target - origin
	local result = workspace:Raycast(origin, direction, params)
	-- Allow a hit right at the target (prompt parented to a part embedded in a wall).
	return result == nil or (result.Position - target).Magnitude < 1.5
end

local function validate(player: Player, prompt: ProximityPrompt, cameraObject: Instance): boolean
	if not CamcorderService.isFilming(player) then
		return false
	end
	local origin, look = CamcorderService.getLook(player)
	if not origin or not look then
		return false
	end
	local target = worldPosition(prompt.Parent or cameraObject)
	if not target then
		return false
	end
	local offset = target - origin
	local distance = offset.Magnitude
	if distance > prompt.MaxActivationDistance + INTERACT.EXTRA_DISTANCE then
		return false
	end
	if distance > 0.5 then
		local angle = math.deg(math.acos(math.clamp(look:Dot(offset.Unit), -1, 1)))
		if angle > INTERACT.MAX_LOOK_ANGLE then
			return false
		end
	end
	return hasLineOfSight(player, origin, target, cameraObject)
end

local function openDoor(door: Instance)
	if door:GetAttribute("Opened") == true then
		return
	end
	door:SetAttribute("Opened", true)
	local parts: { BasePart } = {}
	if door:IsA("BasePart") then
		table.insert(parts, door)
	end
	for _, descendant in door:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		elseif descendant:IsA("ProximityPrompt") then
			descendant:Destroy() -- a used door can't be used again
		end
	end
	local info = TweenInfo.new(INTERACT.DOOR_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, part in parts do
		part.CanCollide = false
		part.CanQuery = false
		TweenService:Create(part, info, { Transparency = 1 }):Play()
	end
end

local function collectPickup(player: Player, pickup: Instance)
	if pickup:GetAttribute("Collected") == true then
		return
	end
	pickup:SetAttribute("Collected", true)
	local kind = pickup:GetAttribute("PickupKind")
	local amount = pickup:GetAttribute("Amount")
	if kind == "Battery" then
		local charge = if typeof(amount) == "number" then amount else INTERACT.DEFAULT_BATTERY_PICKUP
		CamcorderService.addBattery(player, charge)
	else
		local clues = player:GetAttribute(ATTR.Clues)
		local count = if typeof(clues) == "number" then clues else 0
		local gain = if typeof(amount) == "number" then math.floor(amount) else 1
		player:SetAttribute(ATTR.Clues, count + gain)
	end
	pickup:Destroy()
end

local function onTriggered(prompt: ProximityPrompt, player: Player)
	local cameraObject = findTaggedAncestor(prompt, TAGS.CameraOnly)
	if not cameraObject then
		return -- tag was removed since we hooked it
	end
	local now = os.clock()
	local perPlayer = lastUse[player]
	if not perPlayer then
		perPlayer = {}
		lastUse[player] = perPlayer
	end
	local last = perPlayer[prompt]
	if last and now - last < INTERACT.DEBOUNCE then
		return
	end
	perPlayer[prompt] = now

	if not validate(player, prompt, cameraObject) then
		return
	end

	local door = findTaggedAncestor(prompt, TAGS.Door)
	if door then
		openDoor(door)
	end
	local pickup = findTaggedAncestor(prompt, TAGS.Pickup)
	if pickup then
		collectPickup(player, pickup)
	end
	local target = door or pickup or cameraObject
	for _, callback in callbacks do
		task.spawn(callback, player, target, prompt)
	end
end

local function hookPrompt(prompt: ProximityPrompt)
	if hookedPrompts[prompt] then
		return
	end
	hookedPrompts[prompt] = prompt.Triggered:Connect(function(player: Player)
		onTriggered(prompt, player)
	end)
	prompt.Destroying:Connect(function()
		local connection = hookedPrompts[prompt]
		if connection then
			connection:Disconnect()
			hookedPrompts[prompt] = nil
		end
	end)
end

local function onCameraOnlyAdded(instance: Instance)
	if instance:IsA("ProximityPrompt") then
		hookPrompt(instance)
	end
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("ProximityPrompt") then
			hookPrompt(descendant)
		end
	end
	instance.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("ProximityPrompt") then
			hookPrompt(descendant)
		end
	end)
end

function InteractionService.start()
	if started then
		return
	end
	started = true
	CollectionService:GetInstanceAddedSignal(TAGS.CameraOnly):Connect(onCameraOnlyAdded)
	for _, instance in CollectionService:GetTagged(TAGS.CameraOnly) do
		onCameraOnlyAdded(instance)
	end
	game:GetService("Players").PlayerRemoving:Connect(function(player: Player)
		lastUse[player] = nil
	end)
end

function InteractionService.onInteracted(callback: InteractedCallback): () -> ()
	table.insert(callbacks, callback)
	return function()
		local index = table.find(callbacks, callback)
		if index then
			table.remove(callbacks, index)
		end
	end
end

return InteractionService
