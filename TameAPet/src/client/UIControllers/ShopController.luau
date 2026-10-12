-- Shop panel. Prices and availability shown here are for display only; the server re-quotes
-- every purchase from ShopConfig and deducts/grants atomically.

local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Config")
local ShopConfig = require(Config:WaitForChild("ShopConfig"))
local CompassConfig = require(Config:WaitForChild("CompassConfig"))
local GameConfig = require(Config:WaitForChild("GameConfig"))
local Format = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Format"))
local UIKit = require(script.Parent.UIKit)

local Theme = UIKit.Theme

local ShopController = {}

local controllers
local ClientState
local Net
local Notify

local gui: ScreenGui
local grid: ScrollingFrame
local balanceLabel: TextLabel
local pendingProduct: string? = nil

local render: () -> ()

-- Display state for a product: price (or nil), button text, whether it can be clicked.
local function productState(product, profile): (number?, string, boolean)
	if product.kind == "Compass" then
		if ClientState.ownsCompass(product.compassId) then
			return nil, if profile.equippedCompass == product.compassId then "Equipped" else "Owned", false
		end
		return product.price, "Buy", true
	elseif product.kind == "ZoneUnlock" then
		if table.find(profile.unlockedZones, product.zoneId) then
			return nil, "Unlocked", false
		end
		if product.requires and not table.find(profile.unlockedZones, product.requires) then
			return product.price, "Locked", false
		end
		return product.price, "Buy", true
	elseif product.kind == "SpeedUpgrade" then
		local price = ShopConfig.speedUpgradePrice(product, profile.speedUpgradeLevel)
		if not price then
			return nil, "Maxed", false
		end
		return price, "Upgrade", true
	end
	return nil, "Unavailable", false
end

local function buy(button: UIKit.Button, productId: string)
	if pendingProduct then
		return
	end
	pendingProduct = productId
	button.setEnabled(false)
	button.setText("...")
	local result = Net.invoke("Purchase", productId)
	pendingProduct = nil
	Notify.showResult(result)
	render()
end

render = function()
	if not gui.Enabled then
		return
	end
	UIKit.clear(grid, { "UIComponent" })
	local profile = ClientState.profile
	if not profile then
		balanceLabel.Text = "Loading..."
		return
	end
	balanceLabel.Text = `🪙 {Format.commas(profile.currency)} {GameConfig.CurrencyName}`

	local products = table.clone(ShopConfig.Products)
	table.sort(products, function(a, b)
		return a.order < b.order
	end)
	for index, product in products do
		local price, actionText, available = productState(product, profile)
		local accent = Theme.Accent
		if product.kind == "Compass" then
			local compass = CompassConfig.Compasses[product.compassId]
			accent = if compass then compass.color else accent
		elseif product.kind == "ZoneUnlock" then
			accent = Theme.Success
		elseif product.kind == "SpeedUpgrade" then
			accent = Theme.Primary
		end

		local cardFrame = UIKit.new("Frame", {
			BackgroundColor3 = Theme.PanelLight,
			LayoutOrder = index,
			Parent = grid,
		}, { UIKit.corner(12), UIKit.stroke(accent, 2, 0.3) })
		UIKit.icon(product.displayName, accent, 52, cardFrame).Position = UDim2.fromOffset(12, 12)
		UIKit.label({
			Text = product.displayName,
			Font = Theme.FontBlack,
			TextSize = 17,
			Position = UDim2.fromOffset(74, 12),
			Size = UDim2.new(1, -86, 0, 24),
			Parent = cardFrame,
		})
		local subtitle = product.description
		if product.kind == "SpeedUpgrade" then
			subtitle = `{product.description} Level {profile.speedUpgradeLevel} / {product.maxLevel}`
		end
		UIKit.label({
			Text = subtitle,
			TextSize = 13,
			TextColor3 = Theme.TextDim,
			Position = UDim2.fromOffset(74, 38),
			Size = UDim2.new(1, -86, 0, 52),
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = cardFrame,
		})
		local affordable = price ~= nil and profile.currency >= price
		UIKit.label({
			Text = if price then `🪙 {Format.commas(price)}` else "",
			Font = Theme.FontBlack,
			TextSize = 18,
			TextColor3 = if affordable then Theme.Accent else Theme.Danger,
			Position = UDim2.new(0, 14, 1, -46),
			Size = UDim2.fromOffset(140, 36),
			Parent = cardFrame,
		})
		local button
		button = UIKit.button({
			Text = actionText,
			Color = if available then Theme.Success else Theme.Disabled,
			Size = UDim2.fromOffset(120, 36),
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -12, 1, -10),
			Parent = cardFrame,
		}, function()
			if not affordable then
				Notify.show("error", `You need {Format.commas((price or 0) - profile.currency)} more {GameConfig.CurrencyName}.`)
				return
			end
			buy(button, product.id)
		end)
		button.setEnabled(available)
	end
end

function ShopController.open()
	if controllers.InventoryController then
		controllers.InventoryController.close()
	end
	gui.Enabled = true
	render()
end

function ShopController.close()
	if gui then
		gui.Enabled = false
	end
end

function ShopController.toggle()
	if gui.Enabled then
		ShopController.close()
	else
		ShopController.open()
	end
end

function ShopController.init(c)
	controllers = c
	ClientState = c.ClientState
	Net = c.Net
	Notify = c.NotificationController
end

function ShopController.start()
	gui = UIKit.screen("ShopUI", 5)
	gui.Enabled = false
	local window, body = UIKit.window(gui, "Shop", Vector2.new(760, 520), ShopController.close)
	balanceLabel = UIKit.label({
		Text = "",
		Font = Theme.FontBlack,
		TextSize = 18,
		TextColor3 = Theme.Accent,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -56, 0, 14),
		Size = UDim2.fromOffset(260, 28),
		Parent = window,
	})
	grid = UIKit.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		Parent = body,
	}, {
		UIKit.padding(6),
		UIKit.new("UIGridLayout", {
			CellSize = UDim2.fromOffset(350, 150),
			CellPadding = UDim2.fromOffset(12, 12),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	ClientState.ProfileChanged:Connect(render)

	-- The Compass Merchant's prompt only opens this panel; it grants nothing.
	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		if prompt:GetAttribute("OpensShop") then
			ShopController.open()
		end
	end)
end

return ShopController
