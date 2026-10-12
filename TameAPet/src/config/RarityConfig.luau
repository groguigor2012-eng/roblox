--!strict
-- Rarity tiers shared by eggs, pets and items. Add a tier by appending to `Order`
-- and giving it an entry in `Tiers`; everything else looks tiers up from here.

export type RarityTier = {
	rank: number,
	displayName: string,
	color: Color3,
	-- Hatches of this rarity or higher are announced to the whole server.
	announce: boolean,
}

local RarityConfig = {}

RarityConfig.Order = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical", "Secret" }

RarityConfig.Tiers = {
	Common = { rank = 1, displayName = "Common", color = Color3.fromRGB(196, 202, 210), announce = false },
	Uncommon = { rank = 2, displayName = "Uncommon", color = Color3.fromRGB(96, 212, 120), announce = false },
	Rare = { rank = 3, displayName = "Rare", color = Color3.fromRGB(72, 156, 255), announce = false },
	Epic = { rank = 4, displayName = "Epic", color = Color3.fromRGB(176, 96, 255), announce = false },
	Legendary = { rank = 5, displayName = "Legendary", color = Color3.fromRGB(255, 186, 48), announce = true },
	Mythical = { rank = 6, displayName = "Mythical", color = Color3.fromRGB(255, 72, 128), announce = true },
	Secret = { rank = 7, displayName = "Secret", color = Color3.fromRGB(40, 255, 226), announce = true },
} :: { [string]: RarityTier }

function RarityConfig.rank(rarity: string): number
	local tier = RarityConfig.Tiers[rarity]
	return if tier then tier.rank else 0
end

function RarityConfig.color(rarity: string): Color3
	local tier = RarityConfig.Tiers[rarity]
	return if tier then tier.color else Color3.new(1, 1, 1)
end

function RarityConfig.displayName(rarity: string): string
	local tier = RarityConfig.Tiers[rarity]
	return if tier then tier.displayName else rarity
end

return RarityConfig
