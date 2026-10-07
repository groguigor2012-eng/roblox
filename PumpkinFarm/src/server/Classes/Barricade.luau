--!strict
--[[
	Barricade
	Path: ServerScriptService.Server.Classes.Barricade

	A wall that physically blocks ground enemies (Defenses collision group). Its base
	part carries a PathfindingModifier labelled "Barricade" with PassThrough, which the
	Navigator's path costs make expensive: enemies prefer another gate, and when every
	route is sealed they walk up to the barricade and attack it.

	Dependencies: Defense
]]

local Defense = require(script.Parent.Defense)

local Barricade = setmetatable({}, { __index = Defense })
Barricade.__index = Barricade

function Barricade.new(match: any, definition: any, cframe: CFrame, owner: Player?, onDepleted: (any) -> ())
	local self = Defense.new(match, definition, cframe, owner, onDepleted)
	setmetatable(self, Barricade)
	local base = self.Model.PrimaryPart
	if base then
		local modifier = Instance.new("PathfindingModifier")
		modifier.Label = "Barricade"
		modifier.PassThrough = true
		modifier.Parent = base
	end
	return self
end

return Barricade
