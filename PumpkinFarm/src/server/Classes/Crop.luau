--!strict
--[[
	Crop
	Path: ServerScriptService.Server.Classes.Crop

	One planted crop. Growth, health and ripeness are simulated only on the server
	(CropService ticks every crop); the model and its attributes are the replicated,
	read-only view. Implements the damageable-target interface so enemies can attack it.

	Model: Crops/Crop_<uid> (Model) with attributes CropUid, CropId, PlotId, SlotIndex,
	Stage, Growth (0..1), Health, MaxHealth, Ripe, MatchId; a persistent invisible
	"Anchor" part (PrimaryPart, used by client prompts/billboards) and a child "Visual"
	model rebuilt per growth stage.

	Special properties (CropConfig.Special):
		Thorns     -> damages the enemy that bit it (through DamageService)
		Decoy      -> GetTargetPriorityBonus() makes enemies prefer it
		Anchored   -> CanBeStolen() is false (crows peck instead of stealing)
		Regenerate -> heals HealthPerSecond while alive

	Dependencies: Attributes, ModelFactory, Janitor; Registry: DamageService

	API:
		Crop.new(match, definition, slot, plantedBy, growthMultiplier, onDepleted) -> Crop
		crop:Update(dt)
		crop:IsRipe() -> boolean
		crop:IsAlive() -> boolean
		crop:GetPosition() -> Vector3
		crop:GetTargetPriorityBonus() -> number
		crop:CanBeStolen() -> boolean
		crop:TakeDamage(amount, source) -> number
		crop:Heal(fraction)
		crop:ForceRipen()
		crop:Destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local Janitor = require(Shared.Classes.Janitor)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local ModelFactory = require(Server.Systems.ModelFactory)

local Crop = {}
Crop.__index = Crop

local nextUid = 0

export type Slot = { PlotId: string, Index: number, Position: Vector3 }

function Crop.new(match: any, definition: any, slot: Slot, plantedBy: Player, growthMultiplier: number, onDepleted: (crop: any) -> ())
	nextUid += 1
	local self = setmetatable({}, Crop)
	self.Uid = `Crop_{nextUid}`
	self.Kind = "Crop"
	self.CropId = definition.Id
	self.Definition = definition
	self.Match = match
	self.PlotId = slot.PlotId
	self.SlotIndex = slot.Index
	self.Position = slot.Position
	self.PlantedBy = plantedBy
	self.Progress = 0
	self.GrowthRate = math.max(0.1, growthMultiplier) / definition.GrowthDuration
	self.StageIndex = 0
	self.MaxHealth = definition.MaxHealth
	self.Health = definition.MaxHealth
	self.Removed = false
	self.Janitor = Janitor.new()
	self._onDepleted = onDepleted
	self._publishedGrowth = -1

	local model = Instance.new("Model")
	model.Name = self.Uid
	model:SetAttribute(Attributes.CropUid, self.Uid)
	model:SetAttribute(Attributes.CropId, self.CropId)
	model:SetAttribute(Attributes.MatchId, match.Id)
	model:SetAttribute(Attributes.PlotId, slot.PlotId)
	model:SetAttribute(Attributes.SlotIndex, slot.Index)
	self.Model = self.Janitor:Add(model)

	-- Persistent invisible anchor: the visual is rebuilt per stage, so client prompts
	-- and billboards attach here instead.
	local anchor = Instance.new("Part")
	anchor.Name = "Anchor"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CFrame = CFrame.new(slot.Position + Vector3.new(0, 1.5, 0))
	anchor.Parent = model
	model.PrimaryPart = anchor

	self:_refreshStage()
	self:_publish()
	model.Parent = match.Folder:FindFirstChild("Crops")
	return self
end

function Crop:_currentStageIndex(): number
	local index = 1
	for i, stage in self.Definition.Stages do
		if self.Progress >= stage.AtProgress then
			index = i
		end
	end
	return index
end

-- Rebuilds the visual when the growth stage changes (4 rebuilds over a crop's life).
function Crop:_refreshStage()
	local index = self:_currentStageIndex()
	if index == self.StageIndex then
		return
	end
	self.StageIndex = index
	local stage = self.Definition.Stages[index]
	local ok, visualOrError = pcall(ModelFactory.CreateCropVisual, self.Definition, stage.Scale)
	if not ok then
		warn(`[Crop] visual for {self.CropId} failed: {visualOrError}`)
		return
	end
	local visual = visualOrError :: Model
	visual:PivotTo(CFrame.new(self.Position))
	local previous = self.Model:FindFirstChild("Visual")
	if previous then
		previous:Destroy()
	end
	visual.Parent = self.Model
	self.Model:SetAttribute(Attributes.Stage, stage.Name)
end

function Crop:_publish()
	local model = self.Model
	-- Growth replicates in 1% steps so attribute traffic stays tiny.
	local growth = math.floor(self.Progress * 100) / 100
	if growth ~= self._publishedGrowth then
		self._publishedGrowth = growth
		model:SetAttribute(Attributes.Growth, growth)
	end
	model:SetAttribute(Attributes.Health, math.ceil(self.Health))
	model:SetAttribute(Attributes.MaxHealth, self.MaxHealth)
	model:SetAttribute(Attributes.Ripe, self:IsRipe())
end

function Crop:Update(dt: number)
	if self.Removed then
		return
	end
	local changed = false
	if self.Progress < 1 then
		self.Progress = math.min(1, self.Progress + dt * self.GrowthRate)
		self:_refreshStage()
		changed = true
	end
	local special = self.Definition.Special
	if special and special.Type == "Regenerate" and self.Health < self.MaxHealth then
		self.Health = math.min(self.MaxHealth, self.Health + (special.HealthPerSecond or 0) * dt)
		changed = true
	end
	if changed then
		self:_publish()
	end
end

function Crop:IsRipe(): boolean
	return self.Progress >= 1
end

function Crop:IsAlive(): boolean
	return not self.Removed and self.Health > 0
end

function Crop:GetPosition(): Vector3
	return self.Position
end

function Crop:GetTargetPriorityBonus(): number
	local special = self.Definition.Special
	if special and special.Type == "Decoy" then
		return special.PriorityBonus or 0
	end
	return 0
end

function Crop:CanBeStolen(): boolean
	local special = self.Definition.Special
	return not (special and special.Type == "Anchored")
end

function Crop:TakeDamage(amount: number, source: any): number
	if not self:IsAlive() or amount <= 0 then
		return 0
	end
	local movementType = source and source.MovementType or "Ground"
	if source and source.IsBoss then
		movementType = "Boss"
	end
	local vulnerability = (self.Definition.Vulnerability :: any)[movementType] or 1
	local dealt = math.min(self.Health, amount * vulnerability)
	self.Health -= dealt
	self:_publish()

	local special = self.Definition.Special
	if special and special.Type == "Thorns" and source and source.Enemy and source.Enemy:IsAlive() then
		Services.DamageService:DamageEnemy(source.Enemy, special.Damage or 0, { Kind = "Crop", Id = self.CropId })
	end

	if self.Health <= 0 then
		self._onDepleted(self)
	end
	return dealt
end

function Crop:Heal(fraction: number)
	if not self:IsAlive() then
		return
	end
	self.Health = math.min(self.MaxHealth, self.Health + self.MaxHealth * fraction)
	self:_publish()
end

function Crop:ForceRipen()
	self.Progress = 1
	self:_refreshStage()
	self:_publish()
end

function Crop:Destroy()
	if self.Removed then
		return
	end
	self.Removed = true
	self.Janitor:Destroy()
end

return Crop
