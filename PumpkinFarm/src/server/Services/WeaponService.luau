--!strict
--[[
	WeaponService
	Path: ServerScriptService.Server.Services.WeaponService

	Gives each in-match player the weapon of their class and validates every attack
	intent. Clients send only (aimPoint, sequence) / (abilityId, aimPoint); the server
	decides legality, damage, targets, cooldowns and rewards.

	RequestAttack validation:
		session in a match, InMatch and alive -> not stunned (BlocksAttacks) ->
		sequence strictly increasing (replayed/duplicated packets are ignored) ->
		the class weapon Tool is currently equipped -> aim point within MaxAimDistance ->
		weapon cooldown (server clock) -> weapon resolves hits

	RequestUseAbility additionally requires abilityId == the class's ability.

	Weapon modules are resolved from WeaponConfig.Weapons[id].Module under
	ServerScriptService.Server.Classes.Weapons, so new classes only add a module.

	Dependencies: ClassConfig, WeaponConfig, LifeState, Attributes, ModelFactory;
	              Registry: PlayerService, StatusEffectService, RemoteService

	API:
		WeaponService:EquipWeapon(session)
		WeaponService:UnequipWeapon(session)
		WeaponService:HandleAttack(player, aimPoint, sequence)
		WeaponService:HandleAbility(player, abilityId, aimPoint)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local LifeState = require(Shared.Constants.LifeState)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local ModelFactory = require(Server.Systems.ModelFactory)

local WeaponService = {}

local weaponModules: { [string]: any } = {}

local function loadModule(moduleName: string): any
	local cached = weaponModules[moduleName]
	if cached then
		return cached
	end
	local moduleScript = Server.Classes.Weapons:FindFirstChild(moduleName)
	if moduleScript == nil or not moduleScript:IsA("ModuleScript") then
		warn(`[WeaponService] weapon module {moduleName} not found`)
		return nil
	end
	local module = (require :: any)(moduleScript)
	weaponModules[moduleName] = module
	return module
end

function WeaponService:Init() end

function WeaponService:Start()
	Services.RemoteService:OnEvent("RequestAttack", function(player: Player, aimPoint: Vector3, sequence: number)
		self:HandleAttack(player, aimPoint, sequence)
	end)
	Services.RemoteService:OnEvent("RequestUseAbility", function(player: Player, abilityId: string, aimPoint: Vector3)
		self:HandleAbility(player, abilityId, aimPoint)
	end)
end

function WeaponService:EquipWeapon(session: any)
	self:UnequipWeapon(session)
	local classDefinition = session:GetClassDefinition()
	local definition = WeaponConfig.Weapons[classDefinition.WeaponId]
	if definition == nil then
		warn(`[WeaponService] class {classDefinition.Id} references unknown weapon {classDefinition.WeaponId}`)
		return
	end
	local module = loadModule(definition.Module)
	if module == nil then
		return
	end
	local weapon = module.new(session, definition, WeaponConfig.Abilities[classDefinition.AbilityId])
	local tool = ModelFactory.CreateWeaponTool(definition)
	tool:SetAttribute(Attributes.WeaponId, definition.Id)
	tool:SetAttribute("AbilityId", classDefinition.AbilityId)
	weapon:SetTool(tool)
	session.Weapon = weapon

	local backpack = session.Player:FindFirstChildOfClass("Backpack")
	tool.Parent = backpack
	local humanoid = session.Humanoid
	if humanoid then
		humanoid:EquipTool(tool)
	end
end

function WeaponService:UnequipWeapon(session: any)
	local weapon = session.Weapon
	if weapon then
		session.Weapon = nil
		weapon:Destroy()
	end
end

-- Shared checks for attacks and abilities. Returns the weapon when the intent may
-- proceed. Failures are silent: the client already predicted locally and a rejected
-- attack simply does nothing.
local function validateIntent(player: Player, aimPoint: Vector3): any
	local session = Services.PlayerService:GetSession(player)
	if session == nil or session.Match == nil or session.LifeState ~= LifeState.InMatch or not session:IsAlive() then
		return nil
	end
	if Services.StatusEffectService:BlocksAttacks(session) then
		return nil
	end
	local weapon = session.Weapon
	if weapon == nil or weapon.Tool == nil then
		return nil
	end
	local character = session.Character
	if character == nil or weapon.Tool.Parent ~= character then
		return nil
	end
	local position = session:GetPosition()
	if position == nil or (aimPoint - position).Magnitude > WeaponConfig.MaxAimDistance then
		Services.RemoteService:ReportViolation(player, "Attack", "aim out of range")
		return nil
	end
	return weapon
end

function WeaponService:HandleAttack(player: Player, aimPoint: Vector3, sequence: number)
	local session = Services.PlayerService:GetSession(player)
	if session == nil or sequence <= session.LastAttackSequence then
		return
	end
	session.LastAttackSequence = sequence
	local weapon = validateIntent(player, aimPoint)
	if weapon then
		weapon:TryAttack(aimPoint, os.clock())
	end
end

function WeaponService:HandleAbility(player: Player, abilityId: string, aimPoint: Vector3)
	local weapon = validateIntent(player, aimPoint)
	if weapon == nil or weapon.Ability == nil or weapon.Ability.Id ~= abilityId then
		return
	end
	weapon:TryAbility(aimPoint, os.clock())
end

return WeaponService
