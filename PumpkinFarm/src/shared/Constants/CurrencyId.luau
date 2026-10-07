--!strict
--[[
	CurrencyId
	Path: ReplicatedStorage.Shared.Constants.CurrencyId

	The two currencies. MatchCoins are temporary and match-scoped (MatchCoinService);
	Candies are permanent and stored in the player profile (CandyService -> DataService).
]]

return table.freeze({
	MatchCoins = "MatchCoins",
	Candies = "Candies",
})
