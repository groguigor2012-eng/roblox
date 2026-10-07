--!strict
--[[
	Defense
	Path: ServerScriptService.Server.Classes.Defense

	Shared base for placed defenses (Barricade, Sentry): health, upgrade levels,
	repair, model ownership and the damageable-target interface enemies use.

	Model: Defenses/<DefenseId>_<uid> with attributes DefenseUid, DefenseId, Health,
	MaxHealth, Level, MatchId. Every part is in the Defenses collision group (blocks
	enemies, not players).

	Dependencies: Attributes, CollisionGroup, Janitor, ModelFactory, CollisionGroups

	API:
		Defense.new(match, definition, cframe, owner, onDepleted) -> Defense
		defense:IsAlive() -> boolean
		defense:GetPosition() -> Vector3
		defense:TakeDamage(amount, source) -> number
		defense:Repair(fraction) -> number
		defense:GetNextUpgrade() -> upgrade?
		defense:ApplyUpgrade()
		defense:GetMultiplier(field) -> number      -- e.g. "DamageMultiplier" at current level
		defense:Destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local CollisionGroup = require(Shared.Constants.CollisionGroup)
local Janitor = require(Shared.Classes.Janitor)

local Server = script:FindFirstAncestor("Server") :: Instance
local CollisionGroups = require(Server.Systems.CollisionGroups)
local ModelFactory = require(Server.Systems.ModelFactory)

local Defense = {}
Defense.__index = Defense

local nextUid = 0

function Defense.new(match: any, definition: any, cframe: CFrame, owner: Player?, onDepleted: (any) -> ())
	nextUid += 1
	local self = setmetatable({}, Defense)
	self.Uid = `Defense_{nextUid}`
	self.Kind = definition.Kind
	self.DefenseId = definition.Id
	self.Definition = definition
	self.Match = match
	self.Owner = owner
	self.Level = 0
	self.MaxHealth = definition.MaxHealth
	self.Health = definition.MaxHealth
	self.CFrame = cframe
	self.Position = cframe.Position
	self.FootprintRadius = math.max(definition.Size.X, definition.Size.Z) / 2
	self.Janitor = Janitor.new()
	self.Removed = false
	self._onDepleted = onDepleted

	local model = ModelFactory.CreateDefense(definition)
	model.Name = `{definition.Id}_{nextUid}`
	model:SetAttribute(Attributes.DefenseUid, self.Uid)
	model:SetAttribute(Attributes.DefenseId, definition.Id)
	model:SetAttribute(Attributes.MatchId, match.Id)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
	CollisionGroups.SetModel(model, CollisionGroup.Defenses)
	model:PivotTo(cframe)
	self.Model = self.Janitor:Add(model)
	self:_publish()
	model.Parent = match.Folder:FindFirstChild("Defenses")
	return self
end

function Defense:_publish()
	local model = self.Model
	model:SetAttribute(Attributes.Health, math.ceil(self.Health))
	model:SetAttribute(Attributes.MaxHealth, math.ceil(self.MaxHealth))
	model:SetAttribute(Attributes.Level, self.Level)
end

function Defense:IsAlive(): boolean
	return not self.Removed and self.Health > 0
end

function Defense:GetPosition(): Vector3
	return self.Position
end

function Defense:TakeDamage(amount: number, _source: any): number
	if not self:IsAlive() or amount <= 0 then
		return 0
	end
	local dealt = math.min(self.Health, amount)
	self.Health -= dealt
	self:_publish()
	if self.Health <= 0 then
		self._onDepleted(self)
	end
	return dealt
end

function Defense:Repair(fraction: number): number
	if not self:IsAlive() then
		return 0
	end
	local before = self.Health
	self.Health = math.min(self.MaxHealth, self.Health + self.MaxHealth * fraction)
	self:_publish()
	return self.Health - before
end

function Defense:GetNextUpgrade(): any
	local upgrades = self.Definition.Upgrades
	return upgrades and upgrades[self.Level + 1]
end

function Defense:GetMultiplier(field: string): number
	if self.Level == 0 then
		return 1
	end
	local upgrade = self.Definition.Upgrades[self.Level]
	return upgrade and upgrade[field] or 1
end

-- Raises the level; health keeps the same fraction of the new maximum plus the gain.
function Defense:ApplyUpgrade()
	local upgrade = self:GetNextUpgrade()
	if upgrade == nil then
		return
	end
	self.Level += 1
	local newMax = self.Definition.MaxHealth * (upgrade.HealthMultiplier or 1)
	self.Health = math.min(newMax, self.Health + (newMax - self.MaxHealth))
	self.MaxHealth = newMax
	self:OnUpgraded()
	self:_publish()
end

-- Hook for subclasses.
function Defense:OnUpgraded() end

function Defense:Destroy()
	if self.Removed then
		return
	end
	self.Removed = true
	self.Janitor:Destroy()
end

return Defense
