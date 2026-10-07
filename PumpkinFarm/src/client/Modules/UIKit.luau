--!strict
--[[
	UIKit
	Path: StarterPlayerScripts.Client.Modules.UIKit

	Tiny declarative UI builder used by every controller so the HUD has one consistent,
	readable, cartoon look (Palette colours, rounded corners, thick outlines, large
	text). Everything is built in code: no binary .rbxm UI assets are needed, and the
	element names controllers rely on are guaranteed to exist.

	Accessibility defaults: high-contrast text with stroke, TextScaled with a minimum
	and maximum size, touch-sized buttons (min 44 px) on mobile.

	API:
		UIKit.Create(className, props, children?) -> Instance
		UIKit.Screen(name, displayOrder) -> ScreenGui            (parented to PlayerGui)
		UIKit.Corner(radius?) / UIKit.Stroke(color?, thickness?) / UIKit.Padding(px)
		UIKit.List(direction, padding, horizontalAlign?, verticalAlign?) -> UIListLayout
		UIKit.Grid(cellSize, padding) -> UIGridLayout
		UIKit.Panel(props) -> Frame
		UIKit.Label(props) -> TextLabel
		UIKit.Button(props) -> TextButton                        (props.OnClick)
		UIKit.Bar(props) -> Bar { Frame, Fill, Label, Set(fraction, text?) }
		UIKit.Tween(instance, goals, duration?, style?) -> Tween
		UIKit.IsTouch() -> boolean
		UIKit.Fonts, UIKit.Palette
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Palette"))

local UIKit = {}
UIKit.Palette = Palette
UIKit.Fonts = {
	Title = Enum.Font.FredokaOne,
	Body = Enum.Font.GothamBold,
	Light = Enum.Font.GothamMedium,
}

function UIKit.Create(className: string, props: { [string]: any }?, children: { Instance }?): any
	local instance = Instance.new(className)
	local parent = nil
	if props then
		for key, value in props do
			if key == "Parent" then
				parent = value
			else
				(instance :: any)[key] = value
			end
		end
	end
	if children then
		for _, child in children do
			child.Parent = instance
		end
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

function UIKit.IsTouch(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

function UIKit.Screen(name: string, displayOrder: number): ScreenGui
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	return UIKit.Create("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = displayOrder,
		Parent = playerGui,
	})
end

function UIKit.Corner(radius: number?): UICorner
	return UIKit.Create("UICorner", { CornerRadius = UDim.new(0, radius or 12) })
end

function UIKit.Stroke(color: Color3?, thickness: number?): UIStroke
	return UIKit.Create("UIStroke", {
		Color = color or Palette.PanelStroke,
		Thickness = thickness or 3,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function UIKit.Padding(px: number): UIPadding
	local amount = UDim.new(0, px)
	return UIKit.Create("UIPadding", { PaddingTop = amount, PaddingBottom = amount, PaddingLeft = amount, PaddingRight = amount })
end

function UIKit.List(direction: Enum.FillDirection, padding: number, horizontal: Enum.HorizontalAlignment?, vertical: Enum.VerticalAlignment?): UIListLayout
	return UIKit.Create("UIListLayout", {
		FillDirection = direction,
		Padding = UDim.new(0, padding),
		HorizontalAlignment = horizontal or Enum.HorizontalAlignment.Center,
		VerticalAlignment = vertical or Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
end

function UIKit.Grid(cellSize: UDim2, padding: number): UIGridLayout
	return UIKit.Create("UIGridLayout", {
		CellSize = cellSize,
		CellPadding = UDim2.fromOffset(padding, padding),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
	})
end

function UIKit.Panel(props: { [string]: any }): Frame
	local merged = {
		BackgroundColor3 = Palette.Panel,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
	}
	for key, value in props do
		merged[key] = value
	end
	local frame = UIKit.Create("Frame", merged, { UIKit.Corner(14), UIKit.Stroke() })
	return frame
end

local function textDefaults(props: { [string]: any }, font: Enum.Font): { [string]: any }
	local merged: { [string]: any } = {
		BackgroundTransparency = 1,
		TextColor3 = Palette.Text,
		Font = font,
		TextScaled = true,
		TextWrapped = true,
		RichText = true,
	}
	for key, value in props do
		if key ~= "MaxTextSize" and key ~= "MinTextSize" then
			merged[key] = value
		end
	end
	return merged
end

function UIKit.Label(props: { [string]: any }): TextLabel
	local label = UIKit.Create("TextLabel", textDefaults(props, props.Font or UIKit.Fonts.Body))
	UIKit.Create("UITextSizeConstraint", {
		MaxTextSize = props.MaxTextSize or 28,
		MinTextSize = props.MinTextSize or 9,
		Parent = label,
	})
	UIKit.Create("UIStroke", {
		Color = Palette.PanelStroke,
		Thickness = 1.5,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = label,
	})
	return label
end

function UIKit.Tween(instance: Instance, goals: { [string]: any }, duration: number?, style: Enum.EasingStyle?): Tween
	local tween = TweenService:Create(instance, TweenInfo.new(duration or 0.15, style or Enum.EasingStyle.Quad), goals)
	tween:Play()
	return tween
end

function UIKit.Button(props: { [string]: any }): TextButton
	local color = props.Color or Palette.Accent
	local onClick = props.OnClick
	local merged = textDefaults(props, props.Font or UIKit.Fonts.Title)
	merged.OnClick = nil
	merged.Color = nil
	merged.BackgroundTransparency = 0
	merged.BackgroundColor3 = color
	merged.AutoButtonColor = false
	local button = UIKit.Create("TextButton", merged, { UIKit.Corner(12), UIKit.Stroke() })
	UIKit.Create("UITextSizeConstraint", { MaxTextSize = props.MaxTextSize or 24, MinTextSize = 10, Parent = button })
	if UIKit.IsTouch() then
		UIKit.Create("UISizeConstraint", { MinSize = Vector2.new(44, 44), Parent = button })
	end

	local base = color
	button.MouseEnter:Connect(function()
		UIKit.Tween(button, { BackgroundColor3 = base:Lerp(Color3.new(1, 1, 1), 0.2) }, 0.1)
	end)
	button.MouseLeave:Connect(function()
		UIKit.Tween(button, { BackgroundColor3 = base }, 0.1)
	end)
	if onClick then
		button.Activated:Connect(function()
			UIKit.Tween(button, { BackgroundColor3 = base:Lerp(Color3.new(0, 0, 0), 0.2) }, 0.05)
			task.delay(0.08, function()
				UIKit.Tween(button, { BackgroundColor3 = base }, 0.1)
			end)
			onClick()
		end)
	end
	return button
end

export type Bar = {
	Frame: Frame,
	Fill: Frame,
	Label: TextLabel,
	Set: (self: Bar, fraction: number, text: string?) -> (),
}

function UIKit.Bar(props: { [string]: any }): Bar
	local frame = UIKit.Create("Frame", {
		Name = props.Name or "Bar",
		Size = props.Size or UDim2.fromScale(1, 1),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		BackgroundColor3 = props.BackgroundColor or Palette.PanelStroke,
		BorderSizePixel = 0,
		LayoutOrder = props.LayoutOrder or 0,
		Parent = props.Parent,
	}, { UIKit.Corner(8), UIKit.Stroke(Palette.PanelStroke, 2) })
	local fill = UIKit.Create("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = props.Color or Palette.Health,
		BorderSizePixel = 0,
		Parent = frame,
	}, { UIKit.Corner(8) })
	local label = UIKit.Label({
		Name = "Label",
		Size = UDim2.fromScale(1, 1),
		Text = props.Text or "",
		ZIndex = 3,
		MaxTextSize = props.MaxTextSize or 18,
		Parent = frame,
	})
	local bar = { Frame = frame, Fill = fill, Label = label }
	function bar:Set(fraction: number, text: string?)
		local clamped = math.clamp(fraction, 0, 1)
		UIKit.Tween(fill, { Size = UDim2.fromScale(clamped, 1) }, 0.12)
		if text then
			label.Text = text
		end
	end
	return (bar :: any) :: Bar
end

return UIKit
