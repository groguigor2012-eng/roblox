--!strict
--[[
	HarvestChestController
	Path: StarterPlayerScripts.Client.Controllers.HarvestChestController

	ScreenGui "HarvestUI": the Harvest Chest panel (C key, HUD button, or the chest's
	world prompt). Lists every item with quantity and value, the total, the Continue
	risk bonus and the estimated Candies you would bank by escaping now. Also shows a
	compact "chest value" chip on screen during matches.

	API:
		HarvestChestController:Refresh()
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local Format = require(Shared.Utilities.Format)

local Client = script:FindFirstAncestor("Client") :: Instance
local ClientState = require(Client.Modules.ClientState)
local Panels = require(Client.Modules.Panels)
local UIKit = require(Client.Modules.UIKit)

local Palette = UIKit.Palette

local HarvestChestController = {}

local ui: { [string]: any } = {}

function HarvestChestController:Init()
	local screen = UIKit.Screen("HarvestUI", 10)
	local frame = UIKit.Panel({
		Name = "HarvestChest",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.42, 0.56),
		Parent = screen,
	})
	UIKit.Create("UISizeConstraint", { MinSize = Vector2.new(300, 280), MaxSize = Vector2.new(560, 480), Parent = frame })
	UIKit.Label({
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.new(1, -80, 0, 40),
		Text = "📦 Harvest Chest",
		Font = UIKit.Fonts.Title,
		TextXAlignment = Enum.TextXAlignment.Left,
		MaxTextSize = 32,
		Parent = frame,
	})
	UIKit.Button({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 10),
		Size = UDim2.fromOffset(40, 40),
		Text = "✕",
		Color = Palette.Bad,
		OnClick = function()
			Panels.Close("HarvestUI")
		end,
		Parent = frame,
	})
	ui.List = UIKit.Create("ScrollingFrame", {
		Position = UDim2.fromOffset(12, 56),
		Size = UDim2.new(1, -24, 1, -150),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 8,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = frame,
	}, { UIKit.List(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top) })
	ui.Summary = UIKit.Label({
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -10),
		Size = UDim2.new(1, -32, 0, 80),
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Left,
		MaxTextSize = 20,
		Parent = frame,
	})
	Panels.Register("HarvestUI", frame, function()
		HarvestChestController:Refresh()
	end)

	ui.Chip = UIKit.Label({
		Name = "ChestChip",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 10),
		Size = UDim2.fromOffset(200, 30),
		Text = "",
		TextColor3 = Palette.Coin,
		Font = UIKit.Fonts.Title,
		MaxTextSize = 22,
		Visible = false,
		Parent = screen,
	})
end

function HarvestChestController:Refresh()
	for _, child in ui.List:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local chest = ClientState.Chest
	if chest == nil then
		ui.Summary.Text = "No chest yet."
		return
	end
	if #chest.Entries == 0 then
		UIKit.Label({
			Size = UDim2.new(1, 0, 0, 40),
			Text = if chest.Locked then "The harvest was lost..." else "Empty. Harvest ripe crops to fill it!",
			MaxTextSize = 18,
			Parent = ui.List,
		})
	end
	for index, entry in chest.Entries do
		local row = UIKit.Panel({
			LayoutOrder = index,
			Size = UDim2.new(1, -12, 0, 42),
			BackgroundColor3 = Palette.PanelLight,
			Parent = ui.List,
		})
		UIKit.Label({
			Position = UDim2.fromOffset(10, 4),
			Size = UDim2.new(0.62, 0, 1, -8),
			Text = `{entry.Icon} {entry.DisplayName} x{entry.Quantity}`,
			TextXAlignment = Enum.TextXAlignment.Left,
			MaxTextSize = 20,
			Parent = row,
		})
		UIKit.Label({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 4),
			Size = UDim2.new(0.35, 0, 1, -8),
			Text = `{Format.Commas(entry.Value)} 🍬`,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = Palette.Candy,
			MaxTextSize = 20,
			Parent = row,
		})
	end
	ui.Summary.Text = table.concat({
		`Total value: <b>{Format.Commas(chest.TotalValue)}</b>`,
		`Risk bonus: +{Format.Percent(chest.RiskBonus)} (each Continue adds more)`,
		`<font color="#FF6EBE">Escape now for {Format.Commas(chest.EstimatedCandies)} 🍬 Candies</font>`,
	}, "\n")
end

function HarvestChestController:Start()
	ClientState.ChestChanged:Connect(function()
		if Panels.IsOpen("HarvestUI") then
			self:Refresh()
		end
	end)
	ClientState.ObserveMatchAttribute(Attributes.ChestValue, function(value)
		ui.Chip.Visible = value ~= nil
		ui.Chip.Text = `📦 Chest {Format.Commas(value or 0)}`
	end)
	ClientState.MatchChanged:Connect(function(folder)
		if folder == nil then
			Panels.Close("HarvestUI")
		end
	end)
	ContextActionService:BindAction("PF_ToggleChest", function(_, state)
		if state == Enum.UserInputState.Begin and ClientState.InMatch() then
			Panels.Toggle("HarvestUI")
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.C)
end

return HarvestChestController
