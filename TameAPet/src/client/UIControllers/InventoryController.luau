-- Inventory panel with Pets / Compasses / Items tabs. Everything is derived from the server's
-- profile view (one canonical pet list). The panel rebuilds from scratch when the profile
-- changes while it is open; old buttons are destroyed with their connections, so reopening
-- never duplicates handlers. Actions call validated remotes and show the server's answer.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Config")
local CompassConfig = require(Config:WaitForChild("CompassConfig"))
local ItemConfig = require(Config:WaitForChild("ItemConfig"))
local PetConfig = require(Config:WaitForChild("PetConfig"))
local RarityConfig = require(Config:WaitForChild("RarityConfig"))
local UIKit = require(script.Parent.UIKit)
local PetPreview = require(script.Parent.PetPreview)

local Theme = UIKit.Theme

local InventoryController = {}

local controllers
local ClientState
local Net
local Notify

local gui: ScreenGui
local list: ScrollingFrame
local details: Frame
local countLabel: TextLabel
local tabButtons: { [string]: UIKit.Button } = {}

local currentTab = "Pets"
local selected: { [string]: string? } = { Pets = nil, Compasses = nil, Items = nil }
local pending = false

local render: () -> ()

local function isOpen(): boolean
	return gui ~= nil and gui.Enabled
end

-- Runs a request with the button locked, then reports the server's answer.
local function request(button: UIKit.Button, label: string, remote: string, ...: any)
	if pending then
		return
	end
	pending = true
	button.setEnabled(false)
	button.setText("...")
	local result = Net.invoke(remote, ...)
	pending = false
	Notify.showResult(result)
	if button.instance.Parent then
		button.setEnabled(true)
		button.setText(label)
	end
	if result.ok then
		render()
	end
end

local function card(order: number, isSelected: boolean, accent: Color3, onSelect: () -> ()): TextButton
	local button = UIKit.new("TextButton", {
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = if isSelected then Theme.PanelLighter else Theme.PanelLight,
		LayoutOrder = order,
		Parent = list,
	}, {
		UIKit.corner(10),
		UIKit.stroke(if isSelected then Theme.Accent else accent, if isSelected then 3 else 1.5, if isSelected then 0 else 0.4),
	})
	button.Activated:Connect(onSelect)
	return button
end

local function badge(parent: Instance, text: string, color: Color3, position: UDim2)
	local frame = UIKit.new("Frame", {
		BackgroundColor3 = color,
		AnchorPoint = Vector2.new(1, 0),
		Position = position,
		Size = UDim2.fromOffset(0, 18),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = parent,
	}, { UIKit.corner(9), UIKit.new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }) })
	UIKit.label({
		Text = text,
		Font = Theme.FontBlack,
		TextSize = 11,
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = frame,
	})
end

local emptyLabel: TextLabel

local function emptyState(text: string)
	emptyLabel.Text = text
	emptyLabel.Visible = true
end

local function detailText(text: string, order: number, size: number?, color: Color3?, font: Enum.Font?): TextLabel
	return UIKit.label({
		Text = text,
		TextSize = size or 15,
		TextColor3 = color or Theme.Text,
		Font = font or Theme.Font,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = details,
	})
end

-- Pets ---------------------------------------------------------------------------------------

local function renderPetDetails(pet)
	local previewBox = UIKit.new("Frame", {
		BackgroundColor3 = Theme.PanelLight,
		Size = UDim2.new(1, 0, 0, 150),
		LayoutOrder = 1,
		Parent = details,
	}, { UIKit.corner(10) })
	PetPreview.create(previewBox, pet.species, true)

	detailText(pet.displayName, 2, 22, Theme.Text, Theme.FontBlack)
	UIKit.rarityChip(pet.rarity, details, 3)
	detailText(pet.oddsText, 4, 13, Theme.TextDim)

	local statusText = if pet.status == "Tamed" then "Tamed" else "Untamed"
	detailText(`Status: {statusText}{if pet.equipped then " · Equipped" else ""}`, 5, 15,
		if pet.status == "Tamed" then Theme.Success else Theme.Warning, Theme.FontBold)
	local movement = if pet.canFly then "Flying mount" else "Land mount"
	detailText(`{movement} · {pet.speed} studs/s · {table.concat(pet.abilities, ", ")}`, 6, 14, Theme.TextDim)

	local actions = UIKit.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 44),
		LayoutOrder = 8,
		Parent = details,
	}, { UIKit.list(Enum.FillDirection.Horizontal, 8) })

	if pet.status == "Untamed" then
		local have = ClientState.itemCount(pet.requiredItem)
		detailText(
			`Requires: 1 {pet.requiredItemName} (you have {have})`,
			7,
			15,
			if have > 0 then Theme.Success else Theme.Danger,
			Theme.FontBold
		)
		local tameButton
		tameButton = UIKit.button({ Text = "Tame", Color = Theme.Success, Size = UDim2.fromOffset(130, 40), Parent = actions }, function()
			request(tameButton, "Tame", "TamePet", pet.id)
		end)
		tameButton.setEnabled(have > 0)
	else
		local equipLabel = if pet.equipped then "Unequip" else "Equip"
		local equipButton
		equipButton = UIKit.button({
			Text = equipLabel,
			Color = if pet.equipped then Theme.Warning else Theme.Primary,
			Size = UDim2.fromOffset(120, 40),
			Parent = actions,
		}, function()
			request(equipButton, equipLabel, "EquipPet", if pet.equipped then "" else pet.id)
		end)
		if pet.equipped then
			local riding = ClientState.mount.mounted
			UIKit.button({
				Text = if riding then "Dismount" else "Ride",
				Color = if riding then Theme.Danger else Theme.Success,
				Size = UDim2.fromOffset(110, 40),
				Parent = actions,
			}, function()
				controllers.MountInputController.toggleMount()
				InventoryController.close()
			end)
		end
	end
end

local function renderPets(profile)
	countLabel.Text = `Pets {profile.petCount} / {profile.maxPets}`
	if #profile.pets == 0 then
		emptyState("No pets yet.\nBuy a compass and follow it to your first egg!")
		return
	end
	if not selected.Pets or not ClientState.getPet(selected.Pets) then
		selected.Pets = profile.pets[1].id
	end
	for index, pet in profile.pets do
		local isSelected = pet.id == selected.Pets
		local color = RarityConfig.color(pet.rarity)
		local button = card(index, isSelected, color, function()
			selected.Pets = pet.id
			render()
		end)
		UIKit.icon(pet.displayName, color, 56, button).Position = UDim2.fromOffset(10, 10)
		UIKit.label({
			Text = pet.displayName,
			Font = Theme.FontBold,
			TextSize = 14,
			Position = UDim2.fromOffset(8, 72),
			Size = UDim2.new(1, -16, 0, 34),
			Parent = button,
		})
		local chip = UIKit.rarityChip(pet.rarity, button)
		chip.Position = UDim2.fromOffset(8, 108)
		if pet.equipped then
			badge(button, "EQUIPPED", Theme.Primary, UDim2.new(1, -6, 0, 6))
		elseif pet.status == "Untamed" then
			badge(button, if pet.hasRequiredItem then "CAN TAME" else "UNTAMED", if pet.hasRequiredItem then Theme.Success else Theme.Warning, UDim2.new(1, -6, 0, 6))
		else
			badge(button, "TAMED", Theme.Success, UDim2.new(1, -6, 0, 6))
		end
	end
	local pet = ClientState.getPet(selected.Pets :: string)
	if pet then
		renderPetDetails(pet)
	end
end

-- Compasses ----------------------------------------------------------------------------------

local function renderCompasses(profile)
	local ids = {}
	for compassId in CompassConfig.Compasses do
		table.insert(ids, compassId)
	end
	table.sort(ids, function(a, b)
		return CompassConfig.Compasses[a].order < CompassConfig.Compasses[b].order
	end)
	countLabel.Text = `Compasses {#profile.compasses} / {#ids}`
	if not selected.Compasses then
		selected.Compasses = if profile.equippedCompass ~= "" then profile.equippedCompass else ids[1]
	end

	for index, compassId in ids do
		local compass = CompassConfig.Compasses[compassId]
		local owned = ClientState.ownsCompass(compassId)
		local button = card(index, compassId == selected.Compasses, compass.color, function()
			selected.Compasses = compassId
			render()
		end)
		local icon = UIKit.icon(compass.displayName, compass.color, 56, button)
		icon.Position = UDim2.fromOffset(10, 10)
		if not owned then
			icon.BackgroundTransparency = 0.6
		end
		UIKit.label({
			Text = compass.displayName,
			Font = Theme.FontBold,
			TextSize = 14,
			TextColor3 = if owned then Theme.Text else Theme.TextDim,
			Position = UDim2.fromOffset(8, 72),
			Size = UDim2.new(1, -16, 0, 34),
			Parent = button,
		})
		if profile.equippedCompass == compassId then
			badge(button, "EQUIPPED", Theme.Primary, UDim2.new(1, -6, 0, 6))
		elseif not owned then
			badge(button, "LOCKED", Theme.Disabled, UDim2.new(1, -6, 0, 6))
		end
	end

	local compassId = selected.Compasses :: string
	local compass = CompassConfig.Compasses[compassId]
	if not compass then
		return
	end
	detailText(compass.displayName, 1, 22, Theme.Text, Theme.FontBlack)
	detailText(compass.description, 2, 15, Theme.TextDim)
	detailText(`Range: {compass.maxRange} studs`, 3, 15)
	detailText(`Tracks: {RarityConfig.displayName(compass.minTier)} eggs and rarer`, 4, 15)
	local owned = ClientState.ownsCompass(compassId)
	local equipped = profile.equippedCompass == compassId
	if owned then
		local label = if equipped then "Unequip" else "Equip"
		local equipButton
		equipButton = UIKit.button({
			Text = label,
			Color = if equipped then Theme.Warning else Theme.Primary,
			Size = UDim2.fromOffset(140, 40),
			LayoutOrder = 5,
			Parent = details,
		}, function()
			request(equipButton, label, "EquipCompass", if equipped then "" else compassId)
		end)
	else
		UIKit.button({ Text = "Buy in Shop", Color = Theme.Accent, Size = UDim2.fromOffset(140, 40), LayoutOrder = 5, Parent = details }, function()
			InventoryController.close()
			controllers.ShopController.open()
		end)
	end
end

-- Items ------------------------------------------------------------------------------------

local function renderItems(profile)
	local total = 0
	for _, item in profile.items do
		total += item.quantity
	end
	countLabel.Text = `Items {total}`
	if #profile.items == 0 then
		emptyState("No taming items yet.\nRare items are hidden all over the world.")
		return
	end
	local found = false
	for _, item in profile.items do
		if item.id == selected.Items then
			found = true
		end
	end
	if not found then
		selected.Items = profile.items[1].id
	end

	for index, item in profile.items do
		local definition = ItemConfig.Items[item.id]
		local color = if definition then definition.color else RarityConfig.color(item.rarity)
		local button = card(index, item.id == selected.Items, RarityConfig.color(item.rarity), function()
			selected.Items = item.id
			render()
		end)
		local icon = UIKit.icon(item.displayName, color, 56, button)
		icon.Position = UDim2.fromOffset(10, 10)
		if item.quantity == 0 then
			icon.BackgroundTransparency = 0.6
		end
		UIKit.label({
			Text = item.displayName,
			Font = Theme.FontBold,
			TextSize = 14,
			Position = UDim2.fromOffset(8, 72),
			Size = UDim2.new(1, -16, 0, 34),
			Parent = button,
		})
		UIKit.label({
			Text = `x{item.quantity}`,
			Font = Theme.FontBlack,
			TextSize = 18,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -10, 1, -8),
			Size = UDim2.fromOffset(60, 22),
			Parent = button,
		})
		if item.neededBy > 0 then
			badge(button, "NEEDED", if item.quantity > 0 then Theme.Success else Theme.Danger, UDim2.new(1, -6, 0, 6))
		end
	end

	local item
	for _, candidate in profile.items do
		if candidate.id == selected.Items then
			item = candidate
		end
	end
	if not item then
		return
	end
	local definition = ItemConfig.Items[item.id]
	detailText(item.displayName, 1, 22, Theme.Text, Theme.FontBlack)
	UIKit.rarityChip(item.rarity, details, 2)
	detailText(`Owned: {item.quantity}`, 3, 16, Theme.Text, Theme.FontBold)
	if definition then
		detailText(definition.description, 4, 15, Theme.TextDim)
	end
	local tames = {}
	for speciesId, species in PetConfig.Species do
		if species.requiredItem == item.id then
			table.insert(tames, species.displayName)
		end
	end
	table.sort(tames)
	if #tames > 0 then
		detailText(`Tames: {table.concat(tames, ", ")}`, 5, 15)
	end
	if item.neededBy > 0 then
		detailText(`{item.neededBy} of your untamed pets need this item.`, 6, 15, Theme.Accent, Theme.FontBold)
	end
end

-- Frame ------------------------------------------------------------------------------------

render = function()
	if not isOpen() then
		return
	end
	UIKit.clear(list, { "UIComponent" })
	UIKit.clear(details, { "UIComponent" })
	emptyLabel.Visible = false
	for name, button in tabButtons do
		button.setColor(if name == currentTab then Theme.Accent else Theme.PanelLighter)
	end
	local profile = ClientState.profile
	if not profile then
		countLabel.Text = ""
		emptyState("Loading your inventory...")
		return
	end
	if currentTab == "Pets" then
		renderPets(profile)
	elseif currentTab == "Compasses" then
		renderCompasses(profile)
	else
		renderItems(profile)
	end
end

function InventoryController.open()
	if controllers.ShopController then
		controllers.ShopController.close()
	end
	gui.Enabled = true
	render()
end

function InventoryController.close()
	gui.Enabled = false
	UIKit.clear(details, { "UIComponent" }) -- stops preview animations
end

function InventoryController.toggle()
	if isOpen() then
		InventoryController.close()
	else
		InventoryController.open()
	end
end

function InventoryController.showTab(tab: string)
	currentTab = tab
	InventoryController.open()
end

function InventoryController.init(c)
	controllers = c
	ClientState = c.ClientState
	Net = c.Net
	Notify = c.NotificationController
end

function InventoryController.start()
	gui = UIKit.screen("InventoryUI", 5)
	gui.Enabled = false
	local _, body = UIKit.window(gui, "Inventory", Vector2.new(840, 540), InventoryController.close)

	local tabs = UIKit.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 40),
		Parent = body,
	}, { UIKit.list(Enum.FillDirection.Horizontal, 8) })
	for index, tab in { "Pets", "Compasses", "Items" } do
		tabButtons[tab] = UIKit.button({ Text = tab, Size = UDim2.fromOffset(130, 36), LayoutOrder = index, Parent = tabs }, function()
			currentTab = tab
			render()
		end)
	end
	countLabel = UIKit.label({
		Text = "",
		TextColor3 = Theme.TextDim,
		Font = Theme.FontBold,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(220, 36),
		Parent = body,
	})

	list = UIKit.new("ScrollingFrame", {
		Name = "List",
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 48),
		Size = UDim2.new(1, -310, 1, -48),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = body,
	}, {
		UIKit.corner(10),
		UIKit.padding(10),
		UIKit.new("UIGridLayout", {
			CellSize = UDim2.fromOffset(150, 140),
			CellPadding = UDim2.fromOffset(10, 10),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	emptyLabel = UIKit.label({
		Name = "Empty",
		Text = "",
		TextColor3 = Theme.TextDim,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 120),
		Size = UDim2.new(1, -310, 0, 80),
		Visible = false,
		ZIndex = 2,
		Parent = body,
	})
	details = UIKit.new("Frame", {
		Name = "Details",
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.3,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 48),
		Size = UDim2.new(0, 300, 1, -48),
		Parent = body,
	}, {
		UIKit.corner(10),
		UIKit.padding(12),
		UIKit.list(Enum.FillDirection.Vertical, 8),
	})

	-- Live updates while open (e.g. an item picked up or a hatch while browsing).
	ClientState.ProfileChanged:Connect(render)
	ClientState.MountChanged:Connect(render)
end

return InventoryController
