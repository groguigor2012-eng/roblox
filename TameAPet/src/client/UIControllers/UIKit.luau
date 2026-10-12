-- Small UI component kit: consistent theme, rounded panels, buttons with hover/press feedback,
-- labels, rarity chips and screen scaling. All layout is authored at
-- UIConfig.ReferenceResolution and scaled to the device with a UIScale.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = ReplicatedStorage:WaitForChild("Config")
local UIConfig = require(Config:WaitForChild("UIConfig"))
local RarityConfig = require(Config:WaitForChild("RarityConfig"))

local UIKit = {}
UIKit.Theme = UIConfig.Theme

local Theme = UIConfig.Theme

-- Generic constructor: UIKit.new("Frame", { Size = ..., Parent = ... }, { children })
function UIKit.new(className: string, props: { [string]: any }?, children: { Instance }?): any
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

function UIKit.corner(radius: number?): UICorner
	return UIKit.new("UICorner", { CornerRadius = UDim.new(0, radius or Theme.CornerRadius) })
end

function UIKit.stroke(color: Color3?, thickness: number?, transparency: number?): UIStroke
	return UIKit.new("UIStroke", {
		Color = color or Theme.Stroke,
		Thickness = thickness or 1.5,
		Transparency = transparency or 0.3,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function UIKit.padding(all: number): UIPadding
	local p = UDim.new(0, all)
	return UIKit.new("UIPadding", { PaddingTop = p, PaddingBottom = p, PaddingLeft = p, PaddingRight = p })
end

function UIKit.list(direction: Enum.FillDirection, spacing: number, horizontal: Enum.HorizontalAlignment?, vertical: Enum.VerticalAlignment?): UIListLayout
	return UIKit.new("UIListLayout", {
		FillDirection = direction,
		Padding = UDim.new(0, spacing),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = horizontal or Enum.HorizontalAlignment.Left,
		VerticalAlignment = vertical or Enum.VerticalAlignment.Top,
	})
end

function UIKit.panel(props: { [string]: any }): Frame
	local frame = UIKit.new("Frame", {
		BackgroundColor3 = Theme.Panel,
		BorderSizePixel = 0,
	})
	for key, value in props do
		if key ~= "Parent" then
			(frame :: any)[key] = value
		end
	end
	UIKit.corner().Parent = frame
	UIKit.stroke().Parent = frame
	UIKit.new("UIGradient", {
		Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(205, 210, 225)),
		Rotation = 90,
		Parent = frame,
	})
	frame.Parent = props.Parent
	return frame
end

function UIKit.label(props: { [string]: any }): TextLabel
	local textLabel = UIKit.new("TextLabel", {
		BackgroundTransparency = 1,
		Font = Theme.Font,
		TextColor3 = Theme.Text,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		RichText = false,
	})
	for key, value in props do
		if key ~= "Parent" then
			(textLabel :: any)[key] = value
		end
	end
	textLabel.Parent = props.Parent
	return textLabel
end

export type Button = {
	instance: TextButton,
	setEnabled: (boolean) -> (),
	setText: (string) -> (),
	setColor: (Color3) -> (),
}

-- Buttons own exactly one click connection, which is destroyed with the button, so panels
-- that rebuild their content never accumulate duplicate handlers.
function UIKit.button(props: { [string]: any }, onClick: (() -> ())?): Button
	local color = props.Color or Theme.Primary
	local enabled = true
	local instance: TextButton = UIKit.new("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Font = Theme.FontBold,
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = props.TextSize or 16,
		Text = props.Text or "",
		Size = props.Size or UDim2.fromOffset(140, 40),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		Name = props.Name or "Button",
	})
	UIKit.corner(props.CornerRadius or 8).Parent = instance
	local scale = UIKit.new("UIScale", { Parent = instance })
	local stroke = UIKit.stroke(Color3.new(1, 1, 1), 1.5, 0.75)
	stroke.Parent = instance

	local hoverInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad)
	instance.MouseEnter:Connect(function()
		if enabled then
			TweenService:Create(scale, hoverInfo, { Scale = 1.04 }):Play()
			TweenService:Create(instance, hoverInfo, { BackgroundColor3 = color:Lerp(Color3.new(1, 1, 1), 0.15) }):Play()
		end
	end)
	instance.MouseLeave:Connect(function()
		TweenService:Create(scale, hoverInfo, { Scale = 1 }):Play()
		TweenService:Create(instance, hoverInfo, { BackgroundColor3 = if enabled then color else Theme.Disabled }):Play()
	end)
	instance.Activated:Connect(function()
		if not enabled or not onClick then
			return
		end
		scale.Scale = 0.94
		TweenService:Create(scale, TweenInfo.new(0.15, Enum.EasingStyle.Back), { Scale = 1 }):Play()
		onClick()
	end)

	local button: Button = {
		instance = instance,
		setEnabled = function(value: boolean)
			enabled = value
			instance.BackgroundColor3 = if value then color else Theme.Disabled
			instance.TextTransparency = if value then 0 else 0.35
		end,
		setText = function(text: string)
			instance.Text = text
		end,
		setColor = function(newColor: Color3)
			color = newColor
			if enabled then
				instance.BackgroundColor3 = newColor
			end
		end,
	}
	instance.Parent = props.Parent
	return button
end

-- Rounded pill showing a rarity name in its colour.
function UIKit.rarityChip(rarity: string, parent: Instance?, layoutOrder: number?): Frame
	local color = RarityConfig.color(rarity)
	local chip = UIKit.new("Frame", {
		BackgroundColor3 = color,
		BackgroundTransparency = 0.75,
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = layoutOrder or 0,
		Parent = parent,
	}, {
		UIKit.corner(11),
		UIKit.stroke(color, 1.2, 0),
		UIKit.new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
	})
	UIKit.label({
		Text = string.upper(RarityConfig.displayName(rarity)),
		Font = Theme.FontBlack,
		TextSize = 12,
		TextColor3 = color:Lerp(Color3.new(1, 1, 1), 0.35),
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = chip,
	})
	return chip
end

-- Coloured rounded square with initials, used in place of image icons.
function UIKit.icon(text: string, color: Color3, size: number, parent: Instance?): Frame
	local initials = text:gsub("[^%u]", ""):sub(1, 2)
	if initials == "" then
		initials = text:sub(1, 2):upper()
	end
	local frame = UIKit.new("Frame", {
		BackgroundColor3 = color,
		Size = UDim2.fromOffset(size, size),
		Parent = parent,
	}, {
		UIKit.corner(math.floor(size / 4)),
		UIKit.stroke(color:Lerp(Color3.new(1, 1, 1), 0.5), 1.5, 0.2),
	})
	UIKit.label({
		Text = initials,
		Font = Theme.FontBlack,
		TextSize = math.floor(size * 0.4),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.5,
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	})
	return frame
end

-- Returns the player's ScreenGui by name (from StarterGui), creating it if the place doesn't
-- have one, plus a UIScale that keeps it sized for the current screen.
function UIKit.screen(name: string, displayOrder: number, ignoreInset: boolean?): ScreenGui
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild(name, 5)
	if not gui then
		gui = UIKit.new("ScreenGui", {
			Name = name,
			ResetOnSpawn = false,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			DisplayOrder = displayOrder,
			IgnoreGuiInset = ignoreInset == true,
			Parent = playerGui,
		})
	end
	gui.ResetOnSpawn = false
	gui:ClearAllChildren()
	local uiScale = UIKit.new("UIScale", { Name = "AutoScale", Parent = gui })
	local camera = workspace.CurrentCamera
	local function rescale()
		local viewport = camera.ViewportSize
		local reference = UIConfig.ReferenceResolution
		local factor = math.min(viewport.X / reference.X, viewport.Y / reference.Y)
		uiScale.Scale = math.clamp(factor, UIConfig.MinScale, UIConfig.MaxScale)
	end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	rescale()
	return gui
end

-- A centred modal window with a title bar and close button. Returns the window and its body.
function UIKit.window(gui: ScreenGui, title: string, size: Vector2, onClose: () -> ()): (Frame, Frame)
	local window = UIKit.panel({
		Name = "Window",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size.X, size.Y),
		BackgroundColor3 = Theme.Background,
		Parent = gui,
	})
	UIKit.label({
		Name = "Title",
		Text = title,
		Font = Theme.FontBlack,
		TextSize = 24,
		Position = UDim2.fromOffset(18, 10),
		Size = UDim2.new(1, -80, 0, 34),
		Parent = window,
	})
	UIKit.button({
		Name = "Close",
		Text = "X",
		Color = Theme.Danger,
		Size = UDim2.fromOffset(34, 34),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 10),
		Parent = window,
	}, onClose)
	local body = UIKit.new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 54),
		Size = UDim2.new(1, -28, 1, -68),
		Parent = window,
	})
	return window, body
end

function UIKit.clear(container: Instance, keepClasses: { string }?)
	for _, child in container:GetChildren() do
		local keep = false
		if keepClasses then
			for _, className in keepClasses do
				if child:IsA(className) then
					keep = true
					break
				end
			end
		end
		if not keep then
			child:Destroy()
		end
	end
end

function UIKit.tween(instance: Instance, seconds: number, goals: { [string]: any }, style: Enum.EasingStyle?): Tween
	local tween = TweenService:Create(instance, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad), goals)
	tween:Play()
	return tween
end

return UIKit
