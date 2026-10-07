--!strict
--[[
	SeedShopController
	Path: StarterPlayerScripts.Client.Controllers.SeedShopController

	ScreenGui "ShopUI":
		* the Seed Shop panel (toggle with G or the HUD button): one card per stock entry
		  with icon, name, rarity, price, remaining stock, per-player limit and Buy
		* the seed pouch bar (bottom centre, in matches): owned seeds from the profile;
		  tapping one selects it for planting (CropController reads the selection)

	Buying sends (seedId, stockVersion). The version makes a purchase that races a
	restock fail safely with StockChanged instead of buying at a new price.

	API:
		SeedShopController:GetSelectedSeed() -> string?
		SeedShopController:SelectSeed(seedId?)
		SeedShopController:Refresh()
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local CropConfig = require(Shared.Config.CropConfig)
local Format = require(Shared.Utilities.Format)
local Rarity = require(Shared.Data.Rarity)

local Client = script:FindFirstAncestor("Client") :: Instance
local ClientState = require(Client.Modules.ClientState)
local Controllers = require(Client.Modules.ControllerRegistry)
local Net = require(Client.Modules.Net)
local Panels = require(Client.Modules.Panels)
local Signal = require(Shared.Classes.Signal)
local UIKit = require(Client.Modules.UIKit)

local Palette = UIKit.Palette

local SeedShopController = {}
SeedShopController.SelectionChanged = Signal.new()

local ui: { [string]: any } = {}
local selectedSeed: string? = nil
local buying = false

function SeedShopController:GetSelectedSeed(): string?
	return selectedSeed
end

function SeedShopController:SelectSeed(seedId: string?)
	selectedSeed = seedId
	self:RefreshPouch()
	self.SelectionChanged:Fire(seedId)
end

function SeedShopController:Init()
	local screen = UIKit.Screen("ShopUI", 10)
	ui.Screen = screen

	local frame = UIKit.Panel({
		Name = "SeedShop",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.48),
		Size = UDim2.fromScale(0.56, 0.6),
		Parent = screen,
	})
	UIKit.Create("UISizeConstraint", { MinSize = Vector2.new(320, 300), MaxSize = Vector2.new(760, 520), Parent = frame })
	UIKit.Label({
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.new(1, -80, 0, 40),
		Text = "🌱 Seed Shop",
		Font = UIKit.Fonts.Title,
		TextXAlignment = Enum.TextXAlignment.Left,
		MaxTextSize = 34,
		Parent = frame,
	})
	ui.Status = UIKit.Label({
		Position = UDim2.fromOffset(16, 46),
		Size = UDim2.new(1, -32, 0, 22),
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UIKit.Fonts.Light,
		MaxTextSize = 18,
		Parent = frame,
	})
	UIKit.Button({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 10),
		Size = UDim2.fromOffset(40, 40),
		Text = "✕",
		Color = Palette.Bad,
		OnClick = function()
			Panels.Close("ShopUI")
		end,
		Parent = frame,
	})
	ui.List = UIKit.Create("ScrollingFrame", {
		Position = UDim2.fromOffset(12, 74),
		Size = UDim2.new(1, -24, 1, -86),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 8,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = frame,
	}, { UIKit.List(Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top) })
	Panels.Register("ShopUI", frame, function()
		self:Refresh()
	end)

	ui.Pouch = UIKit.Create("Frame", {
		Name = "SeedPouch",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		Size = UDim2.new(0.5, 0, 0, 64),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = screen,
	}, { UIKit.List(Enum.FillDirection.Horizontal, 6) })
end

local function clearChildren(parent: Instance)
	for _, child in parent:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function sortedCropIds(): { string }
	local ids = {}
	for cropId in CropConfig.Crops do
		table.insert(ids, cropId)
	end
	table.sort(ids, function(a, b)
		return (CropConfig.Crops[a].SortOrder or 0) < (CropConfig.Crops[b].SortOrder or 0)
	end)
	return ids
end

function SeedShopController:RefreshPouch()
	clearChildren(ui.Pouch)
	ui.Pouch.Visible = ClientState.InMatch()
	local profile = ClientState.Profile
	local seeds = profile and profile.Seeds or {}
	if selectedSeed and (seeds[selectedSeed] or 0) <= 0 then
		selectedSeed = nil
	end
	local any = false
	for order, cropId in sortedCropIds() do
		local count = seeds[cropId] or 0
		if count > 0 then
			any = true
			local definition = CropConfig.Crops[cropId]
			local selected = selectedSeed == cropId
			UIKit.Button({
				LayoutOrder = order,
				Size = UDim2.fromOffset(92, 58),
				Text = `{definition.Icon} x{count}`,
				Color = if selected then Palette.Good else Palette.PanelLight,
				MaxTextSize = 22,
				OnClick = function()
					self:SelectSeed(if selected then nil else cropId)
				end,
				Parent = ui.Pouch,
			})
		end
	end
	if not any then
		UIKit.Label({
			Size = UDim2.fromOffset(300, 40),
			Text = "No seeds — buy some in the Seed Shop [G]",
			MaxTextSize = 18,
			Parent = ui.Pouch,
		})
	end
end

function SeedShopController:Refresh()
	clearChildren(ui.List)
	local shop = ClientState.Shop
	if shop == nil then
		ui.Status.Text = "The shop opens once you are on a farm."
		return
	end
	ui.Status.Text = if shop.Open
		then "Open! New random stock every intermission. Seeds cost 🍬 Candies and are kept forever."
		else "Closed during waves. Survive to restock!"
	for index, entry in shop.Entries do
		local definition = CropConfig.Get(entry.SeedId)
		if definition then
			local rarity = Rarity[definition.Rarity]
			local card = UIKit.Panel({
				LayoutOrder = index,
				Size = UDim2.new(1, -12, 0, 86),
				BackgroundColor3 = Palette.PanelLight,
				Parent = ui.List,
			})
			UIKit.Create("UIStroke", { Color = rarity and rarity.Color or Palette.PanelStroke, Thickness = 3, Parent = card })
			local limitText = if entry.PerPlayerLimit then `  •  limit {entry.Purchased or 0}/{entry.PerPlayerLimit}` else ""
			UIKit.Label({
				Position = UDim2.fromOffset(12, 6),
				Size = UDim2.new(0.66, 0, 0, 30),
				Text = `{definition.Icon} <b>{definition.DisplayName}</b>  <font color="#{(rarity and rarity.Color or Palette.Text):ToHex()}">{definition.Rarity}</font>`,
				TextXAlignment = Enum.TextXAlignment.Left,
				MaxTextSize = 24,
				Parent = card,
			})
			UIKit.Label({
				Position = UDim2.fromOffset(12, 38),
				Size = UDim2.new(0.66, 0, 0, 42),
				Text = `Grows {definition.GrowthDuration}s • yields {definition.YieldQuantity} x {definition.UnitValue}🍬\nStock: {entry.Quantity}{limitText}`,
				TextXAlignment = Enum.TextXAlignment.Left,
				Font = UIKit.Fonts.Light,
				MaxTextSize = 16,
				Parent = card,
			})
			local canBuy = shop.Open
				and entry.Quantity > 0
				and (entry.PerPlayerLimit == nil or (entry.Purchased or 0) < entry.PerPlayerLimit)
			UIKit.Button({
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -12, 0.5, 0),
				Size = UDim2.new(0.28, 0, 0, 50),
				Text = if entry.Quantity <= 0 then "SOLD OUT" else `BUY 🍬 {Format.Commas(entry.Price)}`,
				Color = if canBuy then Palette.Candy else Palette.PanelStroke,
				OnClick = if canBuy
					then function()
						self:Buy(entry.SeedId, shop.Version)
					end
					else nil,
				Parent = card,
			})
		end
	end
end

function SeedShopController:Buy(seedId: string, version: number)
	if buying then
		return
	end
	buying = true
	task.spawn(function()
		local result = Net:Invoke("RequestBuySeed", seedId, version)
		buying = false
		Controllers.NotificationController:ShowResult(result, "Seed bought!")
		if result.Ok and selectedSeed == nil then
			self:SelectSeed(seedId)
		end
	end)
end

function SeedShopController:Start()
	ClientState.ShopChanged:Connect(function()
		if Panels.IsOpen("ShopUI") then
			self:Refresh()
		end
	end)
	ClientState.ProfileChanged:Connect(function()
		self:RefreshPouch()
	end)
	ClientState.MatchChanged:Connect(function(folder)
		if folder == nil then
			Panels.Close("ShopUI")
		end
		self:RefreshPouch()
	end)
	ContextActionService:BindAction("PF_ToggleSeedShop", function(_, state)
		if state == Enum.UserInputState.Begin and ClientState.InMatch() then
			Panels.Toggle("ShopUI")
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.G)
	self:RefreshPouch()
end

return SeedShopController
