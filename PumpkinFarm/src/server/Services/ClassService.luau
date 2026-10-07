--!strict
--[[
	ClassService
	Path: ServerScriptService.Server.Services.ClassService

	Permanent costumes/classes. Ownership is read from the profile, never from the
	client: RequestSelectClass only succeeds for owned classes and only in the lobby;
	RequestPurchaseClass spends Candies and unlocks inside one atomic profile mutation.

	Classes are data-driven (ClassConfig). Applying a class = costume visuals + base
	stats (PlayerSession:RecomputeStats) + the class weapon (WeaponService, in matches).

	Dependencies: ClassConfig, Attributes, LifeState, ResultCode, Result, ModelFactory;
	              Registry: DataService, PlayerService, RemoteService

	API:
		ClassService:InitializePlayer(session)
		ClassService:ApplyToCharacter(session)
		ClassService:SelectClass(player, classId) -> Result
		ClassService:PurchaseClass(player, classId) -> Result
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local ClassConfig = require(Shared.Config.ClassConfig)
local LifeState = require(Shared.Constants.LifeState)
local Result = require(Shared.Utilities.Result)
local ResultCode = require(Shared.Constants.ResultCode)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local ModelFactory = require(Server.Systems.ModelFactory)

local ClassService = {}

function ClassService:Init() end

function ClassService:Start()
	Services.RemoteService:OnInvoke("RequestSelectClass", function(player: Player, classId: string)
		return self:SelectClass(player, classId)
	end)
	Services.RemoteService:OnInvoke("RequestPurchaseClass", function(player: Player, classId: string)
		return self:PurchaseClass(player, classId)
	end)
end

-- Resolves the equipped class from the profile, falling back to the default when the
-- profile is missing or references a class the player does not (or no longer) own.
function ClassService:InitializePlayer(session: any)
	local player: Player = session.Player
	local data = Services.DataService:GetData(player)
	local classId = ClassConfig.DefaultClassId
	if data and data.EquippedCostume and ClassConfig.Get(data.EquippedCostume) and data.UnlockedCostumes[data.EquippedCostume] then
		classId = data.EquippedCostume
	end
	session.ClassId = classId
	player:SetAttribute(Attributes.ClassId, classId)
end

function ClassService:ApplyToCharacter(session: any)
	local character = session.Character
	if character == nil then
		return
	end
	local definition = session:GetClassDefinition()
	local ok, err = pcall(ModelFactory.ApplyCostume, character, definition)
	if not ok then
		warn(`[ClassService] costume failed for {session.Player.Name}: {err}`)
	end
	session:RecomputeStats()
	local humanoid = session.Humanoid
	if humanoid then
		humanoid.Health = humanoid.MaxHealth
	end
end

function ClassService:SelectClass(player: Player, classId: string)
	local session = Services.PlayerService:GetSession(player)
	if session == nil or not Services.DataService:IsLoaded(player) then
		return Result.Fail(ResultCode.DataNotLoaded)
	end
	if ClassConfig.Get(classId) == nil then
		return Result.Fail(ResultCode.NotFound)
	end
	if session.LifeState ~= LifeState.Lobby and session.LifeState ~= LifeState.Queued then
		return Result.Fail(ResultCode.InvalidState)
	end
	if not Services.DataService:OwnsCostume(player, classId) then
		return Result.Fail(ResultCode.NotOwned)
	end
	if not Services.DataService:SetEquippedCostume(player, classId) then
		return Result.Fail(ResultCode.ServerError)
	end
	session.ClassId = classId
	player:SetAttribute(Attributes.ClassId, classId)
	self:ApplyToCharacter(session)
	return Result.Ok({ ClassId = classId })
end

function ClassService:PurchaseClass(player: Player, classId: string)
	local definition = ClassConfig.Get(classId)
	if definition == nil then
		return Result.Fail(ResultCode.NotFound)
	end
	if not Services.DataService:IsLoaded(player) then
		return Result.Fail(ResultCode.DataNotLoaded)
	end
	-- Check and mutate in one call: nothing can interleave, so double-clicks or
	-- duplicated requests cannot charge twice.
	local ok, outcome = Services.DataService:Update(player, function(data)
		if data.UnlockedCostumes[classId] then
			return ResultCode.AlreadyOwned
		end
		if data.Candies < definition.Price then
			return ResultCode.InsufficientFunds
		end
		data.Candies -= definition.Price
		data.UnlockedCostumes[classId] = true
		return ResultCode.Ok
	end)
	if not ok then
		return Result.Fail(ResultCode.ServerError)
	end
	if outcome ~= ResultCode.Ok then
		return Result.Fail(outcome)
	end
	Services.DataService:RequestSave(player)
	return Result.Ok({ ClassId = classId })
end

return ClassService
