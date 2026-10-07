--!strict
--[[
	BarricadeService
	Path: ServerScriptService.Server.Services.BarricadeService

	Per-match registry of barricades. Creation is only reachable through DefenseService
	(which validates placement and charges coins); destruction happens through
	DefenseService.DestroyDefense (damage, boss crush, match cleanup).

	Dependencies: Barricade

	API:
		BarricadeService:InitMatch(match) / CleanupMatch(match)
		BarricadeService:Create(match, definition, cframe, owner, onDepleted) -> Barricade
		BarricadeService:Remove(barricade)
		BarricadeService:GetBarricades(match) -> { Barricade }
]]

local Server = script:FindFirstAncestor("Server") :: Instance
local Barricade = require(Server.Classes.Barricade)

local BarricadeService = {}

local states: { [any]: { [string]: any } } = {}

function BarricadeService:Init() end

function BarricadeService:InitMatch(match: any)
	states[match] = {}
end

function BarricadeService:CleanupMatch(match: any)
	local barricades = states[match]
	states[match] = nil
	if barricades then
		for _, barricade in barricades do
			barricade:Destroy()
		end
	end
end

function BarricadeService:Create(match: any, definition: any, cframe: CFrame, owner: Player?, onDepleted: (any) -> ()): any
	local barricades = states[match]
	assert(barricades, "[BarricadeService] match not initialised")
	local barricade = Barricade.new(match, definition, cframe, owner, onDepleted)
	barricades[barricade.Uid] = barricade
	return barricade
end

function BarricadeService:Remove(barricade: any)
	local barricades = states[barricade.Match]
	if barricades then
		barricades[barricade.Uid] = nil
	end
	barricade:Destroy()
end

function BarricadeService:GetBarricades(match: any): { any }
	local list = {}
	for _, barricade in states[match] or {} do
		table.insert(list, barricade)
	end
	return list
end

return BarricadeService
