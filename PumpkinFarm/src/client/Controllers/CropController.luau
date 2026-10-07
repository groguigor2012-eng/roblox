--!strict
--[[
	CropController
	Path: StarterPlayerScripts.Client.Controllers.CropController

	Farm interaction on the client:
		* one local ProximityPrompt per empty plot slot: "Plant <seed>" (enabled only
		  when a seed is selected in the pouch and the slot is free)
		* one local ProximityPrompt per ripe crop: "Harvest"
		* a billboard above each crop: name, growth bar or READY!, health when damaged
	Prompts only express intent (RequestPlant / RequestHarvest); the server validates
	ownership, distance, ripeness and occupancy.

	Everything created for a match lives in one Janitor that is cleaned when the
	player leaves the match.

	API: none (self-contained)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local CropConfig = require(Shared.Config.CropConfig)
local Janitor = require(Shared.Classes.Janitor)
local MatchConfig = require(Shared.Config.MatchConfig)

local Client = script:FindFirstAncestor("Client") :: Instance
local ClientState = require(Client.Modules.ClientState)
local Controllers = require(Client.Modules.ControllerRegistry)
local Net = require(Client.Modules.Net)
local UIKit = require(Client.Modules.UIKit)

local Palette = UIKit.Palette

local CropController = {}

local matchJanitor = Janitor.new()
local slotPrompts: { [string]: ProximityPrompt } = {} -- key "Plot1:3"
local occupied: { [string]: boolean } = {}

local function slotKey(plotId: any, slotIndex: any): string
	return `{plotId}:{slotIndex}`
end

local function refreshSlotPrompts()
	local seedId = Controllers.SeedShopController:GetSelectedSeed()
	local definition = seedId and CropConfig.Get(seedId)
	for key, prompt in slotPrompts do
		local free = not occupied[key]
		prompt.Enabled = free and definition ~= nil
		if definition then
			prompt.ActionText = `Plant {definition.DisplayName}`
		end
	end
end

local function plant(prompt: ProximityPrompt)
	local seedId = Controllers.SeedShopController:GetSelectedSeed()
	if seedId == nil then
		return
	end
	local part = prompt.Parent :: BasePart
	local plotId = part:GetAttribute(Attributes.PlotId)
	local slotIndex = part:GetAttribute(Attributes.SlotIndex)
	task.spawn(function()
		local result = Net:Invoke("RequestPlant", plotId, slotIndex, seedId)
		if result.Ok then
			Controllers.AudioController:Play("Plant")
		else
			Controllers.NotificationController:ShowResult(result)
		end
	end)
end

local function bindSlot(part: BasePart)
	local plotId = part:GetAttribute(Attributes.PlotId)
	local slotIndex = part:GetAttribute(Attributes.SlotIndex)
	if plotId == nil or slotIndex == nil then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PlantPrompt"
	prompt.ActionText = "Plant"
	prompt.ObjectText = "Empty plot"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0.3
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = MatchConfig.Interaction.PlantRange - 4
	prompt.Enabled = false
	prompt.Parent = part
	matchJanitor:Add(prompt)
	matchJanitor:Connect(prompt.Triggered, function()
		plant(prompt)
	end)
	slotPrompts[slotKey(plotId, slotIndex)] = prompt
end

local function buildBillboard(model: Model, anchor: BasePart, definition: any): (BillboardGui, any, TextLabel)
	local billboard = UIKit.Create("BillboardGui", {
		Name = "CropInfo",
		Size = UDim2.fromOffset(120, 46),
		StudsOffset = Vector3.new(0, definition.Visual.RipeSize * 0.6 + 1.5, 0),
		AlwaysOnTop = false,
		MaxDistance = 70,
		Adornee = anchor,
		Parent = model,
	})
	local title = UIKit.Label({
		Size = UDim2.new(1, 0, 0, 20),
		Text = `{definition.Icon} {definition.DisplayName}`,
		MaxTextSize = 16,
		Parent = billboard,
	})
	local bar = UIKit.Bar({
		Position = UDim2.fromOffset(10, 24),
		Size = UDim2.new(1, -20, 0, 16),
		Color = Palette.Good,
		MaxTextSize = 12,
		Parent = billboard,
	})
	return billboard, bar, title
end

local function bindCrop(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local cropId = model:GetAttribute(Attributes.CropId)
	local definition = cropId and CropConfig.Get(cropId)
	local anchor = model:WaitForChild("Anchor", 10) :: BasePart?
	if definition == nil or anchor == nil or model.Parent == nil then
		return
	end
	local key = slotKey(model:GetAttribute(Attributes.PlotId), model:GetAttribute(Attributes.SlotIndex))
	occupied[key] = true
	refreshSlotPrompts()

	local cropJanitor = Janitor.new()
	matchJanitor:Add(cropJanitor)
	cropJanitor:Connect(model.AncestryChanged, function()
		if model.Parent == nil then
			occupied[key] = nil
			refreshSlotPrompts()
			cropJanitor:Destroy()
		end
	end)

	local _, bar, title = buildBillboard(model, anchor, definition)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "HarvestPrompt"
	prompt.ActionText = "Harvest"
	prompt.ObjectText = definition.DisplayName
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0.4
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = MatchConfig.Interaction.HarvestRange - 4
	prompt.Enabled = false
	prompt.Parent = anchor
	cropJanitor:Connect(prompt.Triggered, function()
		task.spawn(function()
			local result = Net:Invoke("RequestHarvest", model:GetAttribute(Attributes.CropUid))
			if result.Ok then
				Controllers.AudioController:Play("Harvest")
				Controllers.NotificationController:Notify(`Harvested {definition.Icon} {definition.DisplayName} into the chest!`, "Success", 2)
			else
				Controllers.NotificationController:ShowResult(result)
			end
		end)
	end)

	local function update()
		local ripe = model:GetAttribute(Attributes.Ripe) == true
		local growth = model:GetAttribute(Attributes.Growth) or 0
		local health = model:GetAttribute(Attributes.Health) or 0
		local maxHealth = model:GetAttribute(Attributes.MaxHealth) or 1
		prompt.Enabled = ripe
		if health < maxHealth then
			bar.Fill.BackgroundColor3 = Palette.Bad
			bar:Set(health / maxHealth, if ripe then "READY! (hurt)" else `{math.floor(growth * 100)}% (hurt)`)
		else
			bar.Fill.BackgroundColor3 = if ripe then Palette.Coin else Palette.Good
			bar:Set(if ripe then 1 else growth, if ripe then "READY!" else `{math.floor(growth * 100)}%`)
		end
		title.TextColor3 = if ripe then Palette.Coin else Palette.Text
	end
	for _, attribute in { Attributes.Ripe, Attributes.Growth, Attributes.Health } do
		cropJanitor:Connect(model:GetAttributeChangedSignal(attribute), update)
	end
	update()
end

local function bindMatch(folder: Folder?)
	matchJanitor:Cleanup()
	table.clear(slotPrompts)
	table.clear(occupied)
	if folder == nil then
		return
	end
	local map = folder:WaitForChild("Map", 20)
	local props = map and map:WaitForChild("Props", 20)
	if props then
		for _, child in props:GetChildren() do
			if child:IsA("BasePart") and child:GetAttribute(Attributes.SlotIndex) then
				bindSlot(child)
			end
		end
	end
	local crops = folder:WaitForChild("Crops", 20)
	if crops then
		matchJanitor:Connect(crops.ChildAdded, function(child)
			task.spawn(bindCrop, child)
		end)
		for _, child in crops:GetChildren() do
			task.spawn(bindCrop, child)
		end
	end
	refreshSlotPrompts()
end

function CropController:Init() end

function CropController:Start()
	ClientState.MatchChanged:Connect(function(folder)
		task.spawn(bindMatch, folder)
	end)
	Controllers.SeedShopController.SelectionChanged:Connect(refreshSlotPrompts)
	if ClientState.MatchFolder then
		task.spawn(bindMatch, ClientState.MatchFolder)
	end
end

return CropController
