--!strict
-- Three-heart view of the local Humanoid's health. No image assets: each
-- heart is two round lobes plus a 45°-rotated square, drawn twice (a pale
-- outline heart and a smaller fill heart on top).
--
--   hearts = HealthMath.HeartsFromHealth(Health, MaxHealth, HeartCount)
--
-- The ScreenGui is built once (ResetOnSpawn = false) and re-bound to each new
-- Humanoid by CharacterLifecycle; the health connections live in the
-- character's cleanup group, so respawns never duplicate them. Roblox's
-- default health bar is hidden only after this UI built successfully.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local HealthUIConfig = require(Shared:WaitForChild("Config"):WaitForChild("HealthUIConfig"))
local HealthMath = require(Shared:WaitForChild("Math"):WaitForChild("HealthMath"))
local Logger = require(Shared:WaitForChild("Utilities"):WaitForChild("Logger"))

local Client = script.Parent.Parent
local CharacterLifecycle = require(Client.Utilities.CharacterLifecycle)

type HeartWidget = {
	Root: Frame,
	FillPieces: { Frame },
	FillScale: UIScale,
	OutlineScale: UIScale,
	Filled: boolean,
}

local Layout = HealthUIConfig.Layout
local Style = HealthUIConfig.Style

-- Heart geometry in a unit square. A square of side a rotated 45° has its
-- upper edges' midpoints at (±a/(2√2), -a/(2√2)) from its centre; a lobe of
-- diameter a sits on each. Width = a(1 + 1/√2) = 1 fixes a. Height is
-- a(1/2 + 3/(2√2)); the square's centre is placed so the shape is centred.
local ROOT2 = math.sqrt(2)
local SIDE = 1 / (1 + 1 / ROOT2)
local HEIGHT = SIDE * (0.5 + 1.5 / ROOT2)
local CENTER_Y = (1 - HEIGHT) / 2 + SIDE * (0.5 + 0.5 / ROOT2)
local LOBE_OFFSET = SIDE / (2 * ROOT2)

local logger = Logger.new("HeartUIController")

local HeartUIController = {}

local hearts: { HeartWidget } = {}
local countLabel: TextLabel? = nil
local panelScale: UIScale? = nil
local displayedHearts = -1
local started = false

local function makeShape(parent: Instance, name: string, color: Color3): { Frame }
	local holder = Instance.new("Frame")
	holder.Name = name
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromScale(1, 1)
	holder.Parent = parent

	local pieces: { Frame } = {}
	local function piece(pieceName: string, x: number, y: number, round: boolean, rotation: number)
		local frame = Instance.new("Frame")
		frame.Name = pieceName
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(x, y)
		frame.Size = UDim2.fromScale(SIDE, SIDE)
		frame.Rotation = rotation
		frame.BackgroundColor3 = color
		frame.BorderSizePixel = 0
		if round then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0.5, 0)
			corner.Parent = frame
		end
		frame.Parent = holder
		table.insert(pieces, frame)
	end
	piece("Point", 0.5, CENTER_Y, false, 45)
	piece("LeftLobe", 0.5 - LOBE_OFFSET, CENTER_Y - LOBE_OFFSET, true, 0)
	piece("RightLobe", 0.5 + LOBE_OFFSET, CENTER_Y - LOBE_OFFSET, true, 0)
	return pieces
end

local function makeHeart(parent: Instance, index: number): HeartWidget
	local root = Instance.new("Frame")
	root.Name = `Heart{index}`
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromOffset(Layout.HeartSize, Layout.HeartSize)
	root.LayoutOrder = index
	root.Parent = parent

	local outline = Instance.new("Frame")
	outline.Name = "Outline"
	outline.BackgroundTransparency = 1
	outline.Size = UDim2.fromScale(1, 1)
	outline.Parent = root
	local outlineScale = Instance.new("UIScale")
	outlineScale.Parent = outline
	makeShape(outline, "Shape", Style.OutlineColor)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundTransparency = 1
	fill.AnchorPoint = Vector2.new(0.5, 0.5)
	fill.Position = UDim2.fromScale(0.5, 0.5)
	fill.Size = UDim2.fromScale(Layout.FillScale, Layout.FillScale)
	fill.ZIndex = 2
	fill.Parent = root
	local fillScale = Instance.new("UIScale")
	fillScale.Parent = fill
	local fillPieces = makeShape(fill, "Shape", Style.FilledColor)
	for _, pieceFrame in fillPieces do
		pieceFrame.ZIndex = 2
	end

	return {
		Root = root,
		FillPieces = fillPieces,
		FillScale = fillScale,
		OutlineScale = outlineScale,
		Filled = true,
	}
end

local function setHeartFilled(heart: HeartWidget, filled: boolean, animate: boolean)
	local color = if filled then Style.FilledColor else Style.EmptyColor
	local scale = if filled then 1 else Style.EmptyScale
	local changed = heart.Filled ~= filled
	heart.Filled = filled
	if not animate then
		for _, pieceFrame in heart.FillPieces do
			pieceFrame.BackgroundColor3 = color
		end
		heart.FillScale.Scale = scale
		heart.OutlineScale.Scale = 1
		return
	end
	local info = TweenInfo.new(Style.TransitionTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, pieceFrame in heart.FillPieces do
		TweenService:Create(pieceFrame, info, { BackgroundColor3 = color }):Play()
	end
	TweenService:Create(heart.FillScale, info, { Scale = scale }):Play()
	if changed then
		-- Quick pop of the outline: grow, then settle back.
		heart.OutlineScale.Scale = Style.PopScale
		TweenService:Create(
			heart.OutlineScale,
			TweenInfo.new(Style.TransitionTime * 1.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1 }
		):Play()
	end
end

local function render(health: number, maxHealth: number, animate: boolean)
	local count = HealthMath.HeartsFromHealth(health, maxHealth, HealthUIConfig.HeartCount)
	if count == displayedHearts and animate then
		return
	end
	displayedHearts = count
	for index, heart in hearts do
		setHeartFilled(heart, index <= count, animate)
	end
	if countLabel then
		countLabel.Text = `{count} / {HealthUIConfig.HeartCount}`
	end
end

local function updateScale()
	local camera = Workspace.CurrentCamera
	local scale = panelScale
	if not camera or not scale then
		return
	end
	local height = camera.ViewportSize.Y
	scale.Scale = math.clamp(height / Layout.ReferenceHeight, Layout.MinScale, Layout.MaxScale)
end

local function build(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "HeartUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.DisplayOrder = Layout.DisplayOrder
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0, 0)
	panel.Position = Layout.Position
	panel.AutomaticSize = Enum.AutomaticSize.XY
	panel.Size = UDim2.fromOffset(0, 0)
	panel.BackgroundColor3 = Style.PanelColor
	panel.BackgroundTransparency = Style.PanelTransparency
	panel.BorderSizePixel = 0
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Layout.CornerRadius)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = Style.PanelStrokeColor
	stroke.Transparency = Style.PanelStrokeTransparency
	stroke.Thickness = 1.5
	stroke.Parent = panel
	local padding = Instance.new("UIPadding")
	local pad = UDim.new(0, Layout.PanelPadding)
	padding.PaddingTop, padding.PaddingBottom, padding.PaddingLeft, padding.PaddingRight = pad, pad, pad, pad
	padding.Parent = panel
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, Layout.HeartSpacing)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = panel
	local scale = Instance.new("UIScale")
	scale.Parent = panel
	panelScale = scale

	for index = 1, HealthUIConfig.HeartCount do
		table.insert(hearts, makeHeart(panel, index))
	end

	local label = Instance.new("TextLabel")
	label.Name = "Count"
	label.LayoutOrder = HealthUIConfig.HeartCount + 1
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromOffset(0, Layout.HeartSize)
	label.Font = Style.Font
	label.TextSize = Layout.CountTextSize
	label.TextColor3 = Style.TextColor
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = `{HealthUIConfig.HeartCount} / {HealthUIConfig.HeartCount}`
	label.Parent = panel
	countLabel = label

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return gui
end

local function onSpawn(context: CharacterLifecycle.Context)
	local humanoid = context.Humanoid
	render(humanoid.Health, humanoid.MaxHealth, false)
	context.Cleanup:Connect(humanoid.HealthChanged, function(health: number)
		render(health, humanoid.MaxHealth, true)
	end)
	context.Cleanup:Connect(humanoid:GetPropertyChangedSignal("MaxHealth"), function()
		render(humanoid.Health, humanoid.MaxHealth, true)
	end)
end

function HeartUIController.Start()
	assert(not started, "HeartUIController already started")
	started = true
	build()

	updateScale()
	local cameraConnection: RBXScriptConnection? = nil
	local function watchCamera()
		if cameraConnection then
			cameraConnection:Disconnect()
			cameraConnection = nil
		end
		local camera = Workspace.CurrentCamera
		if camera then
			cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
		end
		updateScale()
	end
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
	watchCamera()

	CharacterLifecycle.Register("HeartUIController", { OnSpawn = onSpawn })

	if HealthUIConfig.DisableDefaultHealthBar then
		local ok, err = pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Health, false)
		if not ok then
			logger:Warn("DefaultHealthBarStillVisible", { Error = err })
		end
	end
end

return HeartUIController
