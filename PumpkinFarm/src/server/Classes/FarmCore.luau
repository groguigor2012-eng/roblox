--!strict
--[[
	FarmCore
	Path: ServerScriptService.Server.Classes.FarmCore

	The Great Pumpkin at the centre of every farm. It is the fallback objective for
	enemies when no crops are planted, and the match is lost if it is destroyed. Its
	health is mirrored to the match folder (CoreHealth / CoreMaxHealth) for the HUD.

	Implements the damageable-target interface (Kind, IsAlive, GetPosition, TakeDamage).

	Dependencies: MatchConfig, Attributes, Signal, ModelFactory

	API:
		FarmCore.new(match, cframe) -> FarmCore
		core:TakeDamage(amount, source) -> number
		core:Heal(fraction)
		core:IsAlive() -> boolean
		core:GetPosition() -> Vector3
		core.Destroyed : Signal()
		core:Destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local MatchConfig = require(Shared.Config.MatchConfig)
local Signal = require(Shared.Classes.Signal)

local Server = script:FindFirstAncestor("Server") :: Instance
local ModelFactory = require(Server.Systems.ModelFactory)

local FarmCore = {}
FarmCore.__index = FarmCore

function FarmCore.new(match: any, cframe: CFrame)
	local self = setmetatable({}, FarmCore)
	self.Kind = "Core"
	self.Match = match
	self.MaxHealth = MatchConfig.Core.MaxHealth
	self.Health = self.MaxHealth
	self.Radius = MatchConfig.Core.Radius
	self.Position = cframe.Position
	self.Destroyed = Signal.new()
	self._dead = false

	self.Model = ModelFactory.CreateCore(self.Radius)
	self.Model:PivotTo(cframe)
	self.Model.Parent = match.Folder

	self:_publish()
	return self
end

function FarmCore:_publish()
	self.Match:SetAttribute(Attributes.CoreHealth, math.ceil(self.Health))
	self.Match:SetAttribute(Attributes.CoreMaxHealth, self.MaxHealth)
end

function FarmCore:IsAlive(): boolean
	return not self._dead
end

function FarmCore:GetPosition(): Vector3
	return self.Position
end

function FarmCore:TakeDamage(amount: number, _source: any): number
	if self._dead or amount <= 0 then
		return 0
	end
	local dealt = math.min(self.Health, amount)
	self.Health -= dealt
	self:_publish()
	if self.Health <= 0 then
		self._dead = true
		self.Destroyed:Fire()
	end
	return dealt
end

function FarmCore:Heal(fraction: number)
	if self._dead then
		return
	end
	self.Health = math.min(self.MaxHealth, self.Health + self.MaxHealth * fraction)
	self:_publish()
end

function FarmCore:Destroy()
	self._dead = true
	self.Destroyed:Destroy()
	if self.Model then
		self.Model:Destroy()
	end
end

return FarmCore
