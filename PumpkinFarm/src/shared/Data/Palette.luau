--!strict
--[[
	Palette
	Path: ReplicatedStorage.Shared.Data.Palette

	The game's colour language: bright, saturated Halloween colours that keep enemy,
	crop and UI silhouettes readable. Used by MapBuilder/ModelFactory (server) and the
	UI kit (client) so the world and the HUD stay visually consistent.
]]

return table.freeze({
	-- World
	Grass = Color3.fromRGB(96, 168, 74),
	GrassDark = Color3.fromRGB(70, 132, 60),
	Soil = Color3.fromRGB(110, 72, 44),
	SoilWet = Color3.fromRGB(84, 54, 34),
	Stone = Color3.fromRGB(122, 118, 134),
	Wood = Color3.fromRGB(150, 104, 62),
	PumpkinOrange = Color3.fromRGB(255, 140, 26),
	PumpkinDark = Color3.fromRGB(214, 98, 10),
	Stem = Color3.fromRGB(70, 130, 40),
	AlienPurple = Color3.fromRGB(150, 70, 230),
	AlienTeal = Color3.fromRGB(40, 220, 200),
	Lantern = Color3.fromRGB(255, 214, 102),

	-- UI
	Panel = Color3.fromRGB(34, 22, 52),
	PanelLight = Color3.fromRGB(58, 40, 86),
	PanelStroke = Color3.fromRGB(20, 12, 30),
	Text = Color3.fromRGB(255, 248, 235),
	TextDim = Color3.fromRGB(200, 186, 214),
	Accent = Color3.fromRGB(255, 152, 32),
	Good = Color3.fromRGB(110, 220, 90),
	Bad = Color3.fromRGB(240, 70, 70),
	Warning = Color3.fromRGB(255, 200, 40),
	Coin = Color3.fromRGB(255, 205, 60),
	Candy = Color3.fromRGB(255, 110, 190),
	Health = Color3.fromRGB(90, 220, 110),
	Boss = Color3.fromRGB(200, 30, 60),
	Info = Color3.fromRGB(120, 190, 255),
})
