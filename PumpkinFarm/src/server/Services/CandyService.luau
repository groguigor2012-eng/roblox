--!strict
--[[
	CandyService
	Path: ServerScriptService.Server.Services.CandyService

	Permanent currency (Global Candies). A thin, audited layer over DataService:
	every grant/spend carries a reason and is logged at debug level, amounts are
	validated as positive integers, and nothing is granted when the profile is not
	loaded (failed loads must never receive rewards that could later be lost or
	duplicated).

	Dependencies: Registry: DataService

	API:
		CandyService:Get(player) -> number
		CandyService:Add(player, amount, reason) -> boolean
		CandyService:TrySpend(player, amount, reason) -> boolean
		CandyService:CanAfford(player, amount) -> boolean
		CandyService.Verbose : boolean   -- print every transaction (Studio debugging)
]]

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)

local CandyService = {}
CandyService.Verbose = false

local function valid(amount: number): boolean
	return type(amount) == "number" and amount == amount and amount > 0 and amount % 1 == 0 and amount < math.huge
end

function CandyService:Init() end

function CandyService:Get(player: Player): number
	return Services.DataService:GetCandies(player)
end

function CandyService:CanAfford(player: Player, amount: number): boolean
	return valid(amount) and Services.DataService:IsLoaded(player) and self:Get(player) >= amount
end

function CandyService:Add(player: Player, amount: number, reason: string): boolean
	if not valid(amount) then
		warn(`[CandyService] rejected grant of {tostring(amount)} to {player.UserId} ({reason})`)
		return false
	end
	local ok = Services.DataService:AddCandies(player, amount)
	if ok and self.Verbose then
		print(`[CandyService] +{amount} -> {player.Name} ({reason})`)
	end
	return ok
end

function CandyService:TrySpend(player: Player, amount: number, reason: string): boolean
	if not valid(amount) then
		return false
	end
	local ok = Services.DataService:SpendCandies(player, amount)
	if ok and self.Verbose then
		print(`[CandyService] -{amount} <- {player.Name} ({reason})`)
	end
	return ok
end

return CandyService
