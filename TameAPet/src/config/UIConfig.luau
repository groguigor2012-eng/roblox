--!strict
-- Visual theme and UI timings. No gameplay rules live here.

local UIConfig = {}

UIConfig.Theme = {
	Font = Enum.Font.GothamMedium,
	FontBold = Enum.Font.GothamBold,
	FontBlack = Enum.Font.GothamBlack,

	Background = Color3.fromRGB(22, 26, 38),
	Panel = Color3.fromRGB(32, 38, 54),
	PanelLight = Color3.fromRGB(44, 52, 72),
	PanelLighter = Color3.fromRGB(58, 68, 92),
	Stroke = Color3.fromRGB(90, 104, 140),
	Text = Color3.fromRGB(240, 244, 255),
	TextDim = Color3.fromRGB(160, 170, 196),
	Accent = Color3.fromRGB(255, 196, 64),
	Primary = Color3.fromRGB(80, 160, 255),
	Success = Color3.fromRGB(70, 200, 120),
	Danger = Color3.fromRGB(235, 80, 90),
	Warning = Color3.fromRGB(255, 170, 60),
	Disabled = Color3.fromRGB(80, 86, 100),

	CornerRadius = 10,
	Padding = 10,
}

-- Layout is authored at this resolution and scaled with a UIScale to fit the screen.
UIConfig.ReferenceResolution = Vector2.new(1280, 720)
UIConfig.MinScale = 0.55
UIConfig.MaxScale = 1.25

UIConfig.Notifications = {
	Duration = 3.5,
	RareDuration = 6,
	MaxVisible = 4,
	-- Identical messages within this window are merged instead of stacking.
	DuplicateWindow = 1.5,
}

UIConfig.Hatch = {
	ShakeCount = 3,
	ShakeTime = 0.35,
	RareShakeCount = 6,
	AutoCloseSeconds = 8,
}

UIConfig.Keybinds = {
	Inventory = Enum.KeyCode.G,
	Shop = Enum.KeyCode.B,
	ToggleMount = Enum.KeyCode.R,
	Ascend = Enum.KeyCode.Space,
	Descend = Enum.KeyCode.LeftControl,
	DescendAlt = Enum.KeyCode.Q,
}

return UIConfig
