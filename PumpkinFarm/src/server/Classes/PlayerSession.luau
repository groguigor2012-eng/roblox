--!strict
--[[
	PlayerSession
	Path: ServerScriptService.Server.Classes.PlayerSession

	Server-side state for one connected player: life state, class, current match,
	character references, match-scoped accessories/cooldowns and per-match statistics.
	It also implements the damageable-target interface used by enemies, so AI code can
	treat players, crops and defenses uniformly:

		Kind, IsAlive(), GetPosition(), TakeDamage(amount, source), OnStatusEffectsChanged()

	Dependencies: ClassConfig, DefenseConfig, LifeState, Attributes, Janitor;
	              Registry: StatusEffectService

	API:
		PlayerSession.new(player) -> PlayerSession
		session:BindCharacter(character) -> boolean
		session:GetRoot() -> BasePart?
		session:GetPosition() -> Vector3?
		session:IsAlive() -> boolean
		session:TakeDamage(amount, source) -> number
		session:Heal(amount) -> number
		session:SetLifeState(state)
		session:RecomputeStats()
		session:GetCoinMultiplier() -> number
		session:ResetMatchState()
		session:OnStatusEffectsChanged()
		session:Destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local ClassConfig = require(Shared.Config.ClassConfig)
local DefenseConfig = require(Shared.Config.DefenseConfig)
local Janitor = require(Shared.Classes.Janitor)
local LifeState = require(Shared.Constants.LifeState)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)

export type MatchStats = {
	Kills: number,
	Harvested: number,
	WavesSurvived: number,
	BossesDefeated: number,
	HighestWave: number,
}

local PlayerSession = {}
PlayerSession.__index = PlayerSession

function PlayerSession.new(player: Player)
	local self = setmetatable({}, PlayerSession)
	self.Player = player
	self.UserId = player.UserId
	self.Kind = "Player"
	self.LifeState = LifeState.Loading
	self.ClassId = ClassConfig.DefaultClassId
	self.Match = nil :: any
	self.Character = nil :: Model?
	self.Humanoid = nil :: Humanoid?
	self.Root = nil :: BasePart?
	self.Janitor = Janitor.new()
	self.CharacterJanitor = self.Janitor:Add(Janitor.new())
	self.SpawnToken = 0
	self.Weapon = nil :: any
	self.Accessories = {} :: { [string]: boolean }
	self.UtilityReadyAt = {} :: { [string]: number }
	self.LastAttackSequence = -1
	self.MatchStats = PlayerSession._emptyStats()
	self.StatsCommitted = false
	self.Destroyed = false
	return self
end

function PlayerSession._emptyStats(): MatchStats
	return { Kills = 0, Harvested = 0, WavesSurvived = 0, BossesDefeated = 0, HighestWave = 0 }
end

-- Validates and stores a freshly spawned character. Returns false if the rig is
-- unusable (no Humanoid / root), which callers treat as a failed spawn.
function PlayerSession:BindCharacter(character: Model): boolean
	self.CharacterJanitor:Cleanup()
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or root == nil or not root:IsA("BasePart") then
		warn(`[PlayerSession] character of {self.Player.Name} is missing Humanoid/HumanoidRootPart`)
		return false
	end
	self.Character = character
	self.Humanoid = humanoid
	self.Root = root
	-- Never let a seat or ragdoll state move a fighting player.
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
	humanoid.BreakJointsOnDeath = false
	self.CharacterJanitor:Add(function()
		if self.Character == character then
			self.Character = nil
			self.Humanoid = nil
			self.Root = nil
		end
	end)
	return true
end

function PlayerSession:GetRoot(): BasePart?
	local root = self.Root
	if root and root.Parent then
		return root
	end
	return nil
end

function PlayerSession:GetPosition(): Vector3?
	local root = self:GetRoot()
	return if root then root.Position else nil
end

function PlayerSession:IsAlive(): boolean
	local humanoid = self.Humanoid
	return not self.Destroyed
		and humanoid ~= nil
		and humanoid.Parent ~= nil
		and humanoid.Health > 0
		and (self.LifeState == LifeState.InMatch or self.LifeState == LifeState.Lobby or self.LifeState == LifeState.Queued)
end

function PlayerSession:GetClassDefinition(): any
	return ClassConfig.Get(self.ClassId) or ClassConfig.Get(ClassConfig.DefaultClassId)
end

-- Applies class armour and status effects (spawn protection) before damage.
function PlayerSession:TakeDamage(amount: number, _source: any): number
	local humanoid = self.Humanoid
	if not self:IsAlive() or humanoid == nil or amount <= 0 then
		return 0
	end
	local classDefinition = self:GetClassDefinition()
	local multiplier = classDefinition.BaseStats.DamageTakenMultiplier
		* Services.StatusEffectService:GetDamageTakenMultiplier(self)
	local dealt = math.min(humanoid.Health, amount * multiplier)
	if dealt <= 0 then
		return 0
	end
	humanoid.Health -= dealt
	return dealt
end

function PlayerSession:Heal(amount: number): number
	local humanoid = self.Humanoid
	if not self:IsAlive() or humanoid == nil or amount <= 0 then
		return 0
	end
	local healed = math.min(amount, humanoid.MaxHealth - humanoid.Health)
	humanoid.Health += healed
	return healed
end

function PlayerSession:SetLifeState(state: string)
	self.LifeState = state
	self.Player:SetAttribute(Attributes.LifeState, state)
end

local function accessoryStat(self: any, statName: string): number
	local total = 0
	for itemId in self.Accessories do
		local item = DefenseConfig.Items[itemId]
		if item and item.Stats and item.Stats[statName] then
			total += item.Stats[statName]
		end
	end
	return total
end

function PlayerSession:GetCoinMultiplier(): number
	return 1 + accessoryStat(self, "CoinMultiplier")
end

-- Recomputes humanoid stats from class base stats + accessories + status effects.
-- Called on spawn, accessory purchase and whenever status effects change.
function PlayerSession:RecomputeStats()
	local humanoid = self.Humanoid
	if humanoid == nil or humanoid.Parent == nil then
		return
	end
	local base = self:GetClassDefinition().BaseStats
	local effects = Services.StatusEffectService

	local inMatch = self.Match ~= nil
	local maxHealth = base.MaxHealth + (if inMatch then accessoryStat(self, "MaxHealth") else 0)
	local walkSpeed = (base.WalkSpeed + (if inMatch then accessoryStat(self, "WalkSpeed") else 0))
		* effects:GetSpeedMultiplier(self)
	local jumpHeight = if effects:BlocksJump(self) then 0 else base.JumpHeight

	if humanoid.Health > 0 then
		local previousMax = humanoid.MaxHealth
		humanoid.MaxHealth = maxHealth
		if maxHealth > previousMax then
			humanoid.Health = math.min(maxHealth, humanoid.Health + (maxHealth - previousMax))
		else
			humanoid.Health = math.min(humanoid.Health, maxHealth)
		end
	end
	humanoid.WalkSpeed = walkSpeed
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = jumpHeight
end

function PlayerSession:OnStatusEffectsChanged()
	self:RecomputeStats()
end

-- Clears everything that only exists inside a match.
function PlayerSession:ResetMatchState()
	self.Match = nil
	table.clear(self.Accessories)
	table.clear(self.UtilityReadyAt)
	self.LastAttackSequence = -1
	self.MatchStats = PlayerSession._emptyStats()
	self.StatsCommitted = false
	self.Player:SetAttribute(Attributes.MatchId, nil)
end

function PlayerSession:Destroy()
	if self.Destroyed then
		return
	end
	self.Destroyed = true
	self.Janitor:Destroy()
end

return PlayerSession
