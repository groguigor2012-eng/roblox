--!strict
-- Owns breakable level geometry. Only BaseParts tagged GroundPoundBreakable
-- are ever considered, and only the server decides what breaks:
--   ProcessImpact(center, radius, power) runs a spatial query restricted to
--   registered breakables, re-validates each candidate (still tagged, still
--   in Workspace, BreakOnGroundPound not false, power >= GroundPoundMinPower)
--   and applies one hit to each, nearest first, up to MaxBreaksPerImpact.
--
-- Hits model: each part needs BreakHits qualifying hits (default 1).
-- ApplyDamage is public so other server systems (e.g. attacks) can reuse it.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local MovementConfig = require(Shared.Config.MovementConfig)
local Logger = require(Shared.Utilities.Logger)
local Types = require(Shared.Types)

type BrokenPartInfo = Types.BrokenPartInfo

type BreakableState = {
	HitsTaken: number,
}

local TAG = GameConfig.Tags.GroundPoundBreakable
local ATTRIBUTES = GameConfig.DestructibleAttributes

local logger = Logger.new("DestructibleService")

local DestructibleService = {}

local registry: { [BasePart]: BreakableState } = {}
local warnedInvalid: { [Instance]: boolean } = {}
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Include
overlapParams.RespectCanCollide = false
local filterDirty = true
local started = false

-- Reads a numeric attribute, warning (once per part) about bad values.
local function readNumber(part: BasePart, attribute: string, default: number, minimum: number): number
	local value = part:GetAttribute(attribute)
	if value == nil then
		return default
	end
	if type(value) ~= "number" or value ~= value or value < minimum then
		if not warnedInvalid[part] then
			warnedInvalid[part] = true
			logger:Warn("InvalidAttribute", { Part = part, Attribute = attribute, Value = tostring(value) })
		end
		return default
	end
	return value
end

local function register(instance: Instance)
	if not instance:IsA("BasePart") then
		if not warnedInvalid[instance] then
			warnedInvalid[instance] = true
			logger:Warn("BreakableNotAPart", { Instance = instance, Class = instance.ClassName })
		end
		return
	end
	if registry[instance] then
		return
	end
	registry[instance] = { HitsTaken = 0 }
	filterDirty = true
end

local function unregister(instance: Instance)
	warnedInvalid[instance] = nil
	if instance:IsA("BasePart") and registry[instance] then
		registry[instance] = nil
		filterDirty = true
	end
end

local function refreshFilter()
	if not filterDirty then
		return
	end
	local parts: { Instance } = {}
	for part in registry do
		table.insert(parts, part)
	end
	overlapParams.FilterDescendantsInstances = parts
	filterDirty = false
end

local function isEligible(part: BasePart, power: number): boolean
	if not registry[part] or not part:IsDescendantOf(Workspace) or not CollectionService:HasTag(part, TAG) then
		return false
	end
	local flag = part:GetAttribute(ATTRIBUTES.BreakOnGroundPound)
	if flag == false then
		return false
	end
	if flag ~= nil and flag ~= true then
		if not warnedInvalid[part] then
			warnedInvalid[part] = true
			logger:Warn("InvalidAttribute", { Part = part, Attribute = ATTRIBUTES.BreakOnGroundPound })
		end
		return false
	end
	return power >= readNumber(part, ATTRIBUTES.MinPower, 0, 0)
end

local function breakPart(part: BasePart)
	local respawnSeconds = readNumber(part, ATTRIBUTES.RespawnSeconds, 0, 0)
	if respawnSeconds <= 0 then
		part:Destroy()
		return
	end
	local parent = part.Parent
	-- Removing from the DataModel also fires the tag's removed signal, which
	-- unregisters it; restoring re-registers it with zero hits taken.
	part.Parent = nil
	task.delay(respawnSeconds, function()
		if parent and parent:IsDescendantOf(game) then
			local ok, err = pcall(function()
				part.Parent = parent
			end)
			if not ok then
				logger:Warn("RespawnFailed", { Part = part.Name, Error = err })
			end
		end
	end)
end

-- Applies hits to a registered breakable. Returns (broke, hitsRemaining).
function DestructibleService.ApplyDamage(part: BasePart, hits: number, source: string): (boolean, number)
	local state = registry[part]
	if not state or hits <= 0 then
		return false, 0
	end
	local required = math.floor(readNumber(part, ATTRIBUTES.BreakHits, 1, 1))
	state.HitsTaken += hits
	local remaining = math.max(0, required - state.HitsTaken)
	if remaining > 0 then
		logger:Debug("BreakableHit", { Part = part, Remaining = remaining, Source = source })
		return false, remaining
	end
	breakPart(part)
	return true, 0
end

-- Server-computed impact. Never receives a part list from a client.
function DestructibleService.ProcessImpact(
	player: Player,
	center: Vector3,
	radius: number,
	power: number
): { BrokenPartInfo }
	refreshFilter()
	local candidates = Workspace:GetPartBoundsInRadius(center, radius, overlapParams)
	table.sort(candidates, function(a, b)
		return (a.Position - center).Magnitude < (b.Position - center).Magnitude
	end)

	local broken: { BrokenPartInfo } = {}
	local maxBreaks = MovementConfig.Validation.MaxBreaksPerImpact
	for _, part in candidates do
		if #broken >= maxBreaks then
			break
		end
		if isEligible(part, power) then
			local info: BrokenPartInfo = {
				CFrame = part.CFrame,
				Size = part.Size,
				Color = part.Color,
				Material = part.Material,
			}
			if DestructibleService.ApplyDamage(part, 1, "GroundPound") then
				table.insert(broken, info)
			end
		end
	end
	if #broken > 0 then
		logger:Debug("ImpactBroke", { UserId = player.UserId, Count = #broken, Power = math.floor(power) })
	end
	return broken
end

function DestructibleService.Start()
	assert(not started, "DestructibleService already started")
	started = true
	if not Workspace:FindFirstChild(GameConfig.Folders.Destructibles) then
		local folder = Instance.new("Folder")
		folder.Name = GameConfig.Folders.Destructibles
		folder.Parent = Workspace
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(register)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unregister)
	for _, instance in CollectionService:GetTagged(TAG) do
		register(instance)
	end
end

return DestructibleService
