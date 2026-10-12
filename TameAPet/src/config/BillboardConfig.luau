--!strict
-- Rarity billboards shown above companion pets and active mounts.

local BillboardConfig = {}

BillboardConfig.MaxDistance = 140 -- studs; hidden beyond this
BillboardConfig.Size = UDim2.fromOffset(220, 78) -- pixels, constant on screen
BillboardConfig.ExtraHeight = 2.5 -- studs above the model's top
BillboardConfig.NameTextSize = 20
BillboardConfig.RarityTextSize = 16
BillboardConfig.OddsTextSize = 13
BillboardConfig.ShowOwnerName = true
BillboardConfig.BackgroundTransparency = 0.45

return BillboardConfig
