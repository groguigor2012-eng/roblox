-- Server-created BillboardGui showing a pet's name, rarity and configured odds above
-- companion pets and active mounts. Built on the server from trusted data, so other
-- players' clients can't change what everyone sees.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BillboardConfig = require(ReplicatedStorage.Config.BillboardConfig)
local RarityConfig = require(ReplicatedStorage.Config.RarityConfig)

local RarityBillboard = {}

export type Info = {
	displayName: string,
	rarity: string,
	oddsText: string,
	ownerName: string?,
}

local function label(name: string, text: string, size: number, color: Color3, order: number, font: Enum.Font): TextLabel
	local textLabel = Instance.new("TextLabel")
	textLabel.Name = name
	textLabel.BackgroundTransparency = 1
	textLabel.Size = UDim2.new(1, 0, 0, size + 4)
	textLabel.Font = font
	textLabel.TextSize = size
	textLabel.TextColor3 = color
	textLabel.TextStrokeTransparency = 0.4
	textLabel.Text = text
	textLabel.LayoutOrder = order
	return textLabel
end

function RarityBillboard.attach(model: Model, info: Info): BillboardGui
	local root = model.PrimaryPart :: BasePart
	local boxCFrame, size = model:GetBoundingBox()
	local heightAboveRoot = boxCFrame.Position.Y - root.Position.Y + size.Y / 2

	local gui = Instance.new("BillboardGui")
	gui.Name = "RarityBillboard"
	gui.Adornee = root
	gui.Size = BillboardConfig.Size
	gui.StudsOffsetWorldSpace = Vector3.new(0, heightAboveRoot + BillboardConfig.ExtraHeight, 0)
	gui.MaxDistance = BillboardConfig.MaxDistance
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0

	local frame = Instance.new("Frame")
	frame.Name = "Card"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(20, 22, 32)
	frame.BackgroundTransparency = BillboardConfig.BackgroundTransparency
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = RarityConfig.color(info.rarity)
	stroke.Thickness = 1.5
	stroke.Parent = frame
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = frame

	local name = info.displayName
	if BillboardConfig.ShowOwnerName and info.ownerName then
		name = `{info.ownerName}'s {info.displayName}`
	end
	label("Name", name, BillboardConfig.NameTextSize, Color3.new(1, 1, 1), 1, Enum.Font.GothamBold).Parent = frame
	label(
		"Rarity",
		string.upper(RarityConfig.displayName(info.rarity)),
		BillboardConfig.RarityTextSize,
		RarityConfig.color(info.rarity),
		2,
		Enum.Font.GothamBlack
	).Parent = frame
	label("Odds", info.oddsText, BillboardConfig.OddsTextSize, Color3.fromRGB(210, 214, 230), 3, Enum.Font.GothamMedium).Parent = frame

	gui.Parent = model
	return gui
end

return RarityBillboard
