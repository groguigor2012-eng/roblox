--!strict
--[[
	ClassController
	Path: StarterPlayerScripts.Client.Controllers.ClassController

	Two lobby panels:
		ClassUI    costume/class cards: role, stats, weapon, ability, price; Buy or Equip
		UpgradeUI  permanent Candy upgrades with current level and next cost
	Both are rebuilt from the replicated profile view. Ownership and prices shown here
	are for display only; the server re-validates everything.

	API:
		ClassController:Refresh()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local ClassConfig = require(Shared.Config.ClassConfig)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local Format = require(Shared.Utilities.Format)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local Client = script:FindFirstAncestor("Client") :: Instance
local ClientState = require(Client.Modules.ClientState)
local Controllers = require(Client.Modules.ControllerRegistry)
local Net = require(Client.Modules.Net)
local Panels = require(Client.Modules.Panels)
local UIKit = require(Client.Modules.UIKit)

local Palette = UIKit.Palette

local ClassController = {}

local classList: Frame
local upgradeList: Frame

local function panel(screen: ScreenGui, name: string, title: string): (Frame, Frame)
	local frame = UIKit.Panel({
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.62, 0.66),
		Parent = screen,
	})
	UIKit.Create("UISizeConstraint", { MinSize = Vector2.new(320, 300), MaxSize = Vector2.new(820, 560), Parent = frame })
	UIKit.Label({
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.new(1, -80, 0, 44),
		Text = title,
		Font = UIKit.Fonts.Title,
		TextXAlignment = Enum.TextXAlignment.Left,
		MaxTextSize = 34,
		Parent = frame,
	})
	UIKit.Button({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 10),
		Size = UDim2.fromOffset(40, 40),
		Text = "✕",
		Color = Palette.Bad,
		OnClick = function()
			Panels.Close(name)
		end,
		Parent = frame,
	})
	local list = UIKit.Create("ScrollingFrame", {
		Name = "List",
		Position = UDim2.fromOffset(12, 60),
		Size = UDim2.new(1, -24, 1, -72),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 8,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = frame,
	}, { UIKit.List(Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top) })
	return frame, list
end

function ClassController:Init()
	local screen = UIKit.Screen("ClassUI", 10)
	local classFrame
	classFrame, classList = panel(screen, "ClassUI", "👗 Wardrobe — Costumes & Classes")
	Panels.Register("ClassUI", classFrame, function()
		self:Refresh()
	end)

	local upgradeScreen = UIKit.Screen("UpgradeUI", 10)
	local upgradeFrame
	upgradeFrame, upgradeList = panel(upgradeScreen, "UpgradeUI", "🍬 Permanent Upgrades")
	Panels.Register("UpgradeUI", upgradeFrame, function()
		self:Refresh()
	end)
end

local function clear(list: Frame)
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function invokeAndReport(remote: string, id: string, successText: string)
	task.spawn(function()
		local result = Net:Invoke(remote, id)
		Controllers.NotificationController:ShowResult(result, successText)
	end)
end

function ClassController:Refresh()
	local profile = ClientState.Profile
	if profile == nil then
		return
	end

	clear(classList)
	local classes = {}
	for _, definition in ClassConfig.Classes do
		table.insert(classes, definition)
	end
	table.sort(classes, function(a, b)
		return a.SortOrder < b.SortOrder
	end)
	for index, definition in classes do
		local owned = profile.UnlockedCostumes[definition.Id] == true
		local equipped = profile.EquippedCostume == definition.Id
		local weapon = WeaponConfig.Weapons[definition.WeaponId]
		local ability = WeaponConfig.Abilities[definition.AbilityId]
		local card = UIKit.Panel({
			LayoutOrder = index,
			Size = UDim2.new(1, -12, 0, 150),
			BackgroundColor3 = Palette.PanelLight,
			Parent = classList,
		})
		UIKit.Label({
			Position = UDim2.fromOffset(12, 8),
			Size = UDim2.new(0.7, 0, 0, 32),
			Text = `{definition.Icon} <b>{definition.DisplayName}</b>  <font color="#C8BAD6">{definition.Role}</font>`,
			TextXAlignment = Enum.TextXAlignment.Left,
			MaxTextSize = 26,
			Parent = card,
		})
		UIKit.Label({
			Position = UDim2.fromOffset(12, 42),
			Size = UDim2.new(0.68, 0, 0, 100),
			Text = `{definition.Description}\n❤ {definition.BaseStats.MaxHealth} HP  👟 {definition.BaseStats.WalkSpeed} speed\n⚔ {weapon and weapon.DisplayName or "?"} ({weapon and weapon.Damage or 0} dmg)\n✨ {ability and ability.DisplayName or "?"}: {ability and ability.Description or ""}`,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Font = UIKit.Fonts.Light,
			MaxTextSize = 16,
			Parent = card,
		})
		local buttonText, buttonColor, onClick
		if equipped then
			buttonText, buttonColor = "EQUIPPED", Palette.PanelStroke
		elseif owned then
			buttonText, buttonColor = "EQUIP", Palette.Good
			onClick = function()
				invokeAndReport("RequestSelectClass", definition.Id, `{definition.DisplayName} equipped!`)
			end
		else
			buttonText, buttonColor = `BUY 🍬 {Format.Commas(definition.Price)}`, Palette.Candy
			onClick = function()
				invokeAndReport("RequestPurchaseClass", definition.Id, `Unlocked the {definition.DisplayName}!`)
			end
		end
		UIKit.Button({
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			Size = UDim2.new(0.28, 0, 0, 52),
			Text = buttonText,
			Color = buttonColor,
			OnClick = onClick,
			Parent = card,
		})
	end

	clear(upgradeList)
	local upgrades = {}
	for _, definition in EconomyConfig.PermanentUpgrades do
		table.insert(upgrades, definition)
	end
	table.sort(upgrades, function(a, b)
		return a.SortOrder < b.SortOrder
	end)
	for index, definition in upgrades do
		local level = profile.PermanentUpgrades[definition.Id] or 0
		local nextCost = definition.Costs[level + 1]
		local card = UIKit.Panel({
			LayoutOrder = index,
			Size = UDim2.new(1, -12, 0, 90),
			BackgroundColor3 = Palette.PanelLight,
			Parent = upgradeList,
		})
		UIKit.Label({
			Position = UDim2.fromOffset(12, 8),
			Size = UDim2.new(0.68, 0, 0, 74),
			Text = `{definition.Icon} <b>{definition.DisplayName}</b>  Lv {level}/{#definition.Costs}\n<font size="16">{definition.Description}</font>`,
			TextXAlignment = Enum.TextXAlignment.Left,
			MaxTextSize = 22,
			Parent = card,
		})
		UIKit.Button({
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			Size = UDim2.new(0.28, 0, 0, 48),
			Text = if nextCost then `🍬 {Format.Commas(nextCost)}` else "MAX",
			Color = if nextCost then Palette.Candy else Palette.PanelStroke,
			OnClick = if nextCost
				then function()
					invokeAndReport("RequestPurchaseUpgrade", definition.Id, `{definition.DisplayName} upgraded!`)
				end
				else nil,
			Parent = card,
		})
	end
end

function ClassController:Start()
	ClientState.ProfileChanged:Connect(function()
		if Panels.IsOpen("ClassUI") or Panels.IsOpen("UpgradeUI") then
			self:Refresh()
		end
	end)
end

return ClassController
