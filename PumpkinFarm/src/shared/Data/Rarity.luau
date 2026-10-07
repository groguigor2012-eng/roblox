--!strict
--[[
	Rarity
	Path: ReplicatedStorage.Shared.Data.Rarity

	Rarity tiers shared by crops, seeds and shop UI. Order drives sorting; Color drives
	UI accents and crop glow.
]]

export type RarityInfo = {
	Id: string,
	DisplayName: string,
	Order: number,
	Color: Color3,
}

local Rarity: { [string]: RarityInfo } = {
	Common = { Id = "Common", DisplayName = "Common", Order = 1, Color = Color3.fromRGB(168, 230, 112) },
	Uncommon = { Id = "Uncommon", DisplayName = "Uncommon", Order = 2, Color = Color3.fromRGB(96, 196, 255) },
	Rare = { Id = "Rare", DisplayName = "Rare", Order = 3, Color = Color3.fromRGB(190, 110, 255) },
	Epic = { Id = "Epic", DisplayName = "Epic", Order = 4, Color = Color3.fromRGB(255, 120, 60) },
}

for _, info in Rarity do
	table.freeze(info)
end

return table.freeze(Rarity)
