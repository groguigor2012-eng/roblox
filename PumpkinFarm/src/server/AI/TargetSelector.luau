--!strict
--[[
	TargetSelector
	Path: ServerScriptService.Server.AI.TargetSelector

	Objective selection shared by every enemy. Candidates are gathered from the match's
	registries (never from workspace scans) and scored:

		score = TargetPriority[kind] * (1 + crop decoy bonus) / (1 + distance / 40)

	Players are only candidates inside the enemy's DetectionRange (aggro), and are
	dropped beyond LeashRange. A current target is kept unless a new one scores 30%
	better, which prevents target flip-flopping between two equal crops.

	Dependencies: MathUtil; Registry: CropService, DefenseService

	API:
		TargetSelector.Select(enemy, options?) -> target?
			options = { Kinds: { [kind]: boolean }?, Origin: Vector3? }
		TargetSelector.GetRadius(target) -> number      -- how far its surface is from its centre
		TargetSelector.GetApproachPoint(enemy, target) -> Vector3
			-- walkable point just outside a solid target (the Great Pumpkin, a barricade),
			-- on the enemy's side; PathfindingService rejects goals inside obstacles
		TargetSelector.IsValid(enemy, target) -> boolean
]]

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)

local DISTANCE_FALLOFF = 40
local KEEP_TARGET_RATIO = 1.3

local TargetSelector = {}

function TargetSelector.GetRadius(target: any): number
	if target == nil then
		return 0
	end
	if target.Kind == "Core" then
		return target.Radius or 6
	elseif target.Kind == "Barricade" or target.Kind == "Sentry" then
		return target.FootprintRadius or 3
	elseif target.Kind == "Crop" then
		return 1.5
	end
	return 1.5
end

function TargetSelector.GetApproachPoint(enemy: any, target: any): Vector3
	local position = target:GetPosition()
	local radius = TargetSelector.GetRadius(target)
	if radius <= 2 then
		return position
	end
	local from = enemy:GetPosition()
	local offset = Vector3.new(from.X - position.X, 0, from.Z - position.Z)
	local direction = if offset.Magnitude > 0.1 then offset.Unit else Vector3.new(0, 0, 1)
	return position + direction * (radius + 1.5)
end

function TargetSelector.IsValid(enemy: any, target: any): boolean
	if target == nil or not target:IsAlive() then
		return false
	end
	if target.Kind == "Player" then
		if target.Match ~= enemy.Match then
			return false
		end
		local position = target:GetPosition()
		local leash = enemy.Definition.LeashRange or 0
		return position ~= nil and (position - enemy:GetPosition()).Magnitude <= leash
	end
	return true
end

local function scoreOf(weight: number, distance: number, bonus: number): number
	return weight * (1 + bonus) / (1 + distance / DISTANCE_FALLOFF)
end

function TargetSelector.Select(enemy: any, options: { Kinds: { [string]: boolean }?, Origin: Vector3? }?): any
	local match = enemy.Match
	local priority = enemy.Definition.TargetPriority or {}
	local kinds = options and options.Kinds
	local origin = (options and options.Origin) or enemy:GetPosition()

	local function allowed(kind: string): boolean
		return (priority[kind] or 0) > 0 and (kinds == nil or kinds[kind] == true)
	end

	local best, bestScore = nil, 0
	local function consider(target: any, kind: string, bonus: number)
		if not target:IsAlive() then
			return
		end
		local position = target:GetPosition()
		if position == nil then
			return
		end
		local score = scoreOf(priority[kind], (position - origin).Magnitude, bonus)
		if score > bestScore then
			best, bestScore = target, score
		end
	end

	if allowed("Player") then
		local detection = enemy.Definition.DetectionRange or 0
		for _, session in match:GetLivingSessions() do
			local position = session:GetPosition()
			if position and (position - origin).Magnitude <= detection then
				consider(session, "Player", 0)
			end
		end
	end
	if allowed("Crop") then
		for _, crop in Services.CropService:GetCrops(match) do
			consider(crop, "Crop", crop:GetTargetPriorityBonus())
		end
	end
	if allowed("Core") and match.Core then
		consider(match.Core, "Core", 0)
	end
	if allowed("Barricade") or allowed("Sentry") then
		for _, defense in Services.DefenseService:GetDefenses(match) do
			if allowed(defense.Kind) then
				consider(defense, defense.Kind, 0)
			end
		end
	end

	-- Hysteresis: keep the current target unless the best is clearly better.
	local current = enemy.Target
	if current and current ~= best and TargetSelector.IsValid(enemy, current) and current.Kind and priority[current.Kind] then
		local position = current:GetPosition()
		if position then
			local bonus = if current.Kind == "Crop" then current:GetTargetPriorityBonus() else 0
			local currentScore = scoreOf(priority[current.Kind], (position - origin).Magnitude, bonus)
			if currentScore * KEEP_TARGET_RATIO >= bestScore then
				return current
			end
		end
	end
	return best
end

return TargetSelector
