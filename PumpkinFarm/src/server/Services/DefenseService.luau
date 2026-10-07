--!strict
--[[
	DefenseService
	Path: ServerScriptService.Server.Services.DefenseService

	Everything bought with Match Coins: placed defenses (delegated to BarricadeService /
	SentryService), defense upgrades, accessories and utilities. Also the unified query
	API the AI uses for "any defense".

	Placement validation (ValidatePlacement), all server-side:
		1. ring around the farm centre (Placement.InnerRadius..OuterRadius) and inside
		   the arena bounds (with the footprint)
		2. the buyer stands within MaxPlaceDistance of the spot
		3. a downward raycast finds diggable floor within MaxGroundSnap of the requested
		   height (not a plot, rock, foundation or chest pad)
		4. the footprint box (+Clearance) overlaps nothing solid: other defenses, crops,
		   props, fences, rocks, plots, the Great Pumpkin, the chest
		5. per-match caps (MaxDefensesPerMatch, MaxSentriesPerMatch)
	Then coins are spent; if construction fails the coins are refunded.

	Dependencies: DefenseConfig, MatchState, LifeState, Attributes, CurrencyId,
	              MathUtil, Result, ResultCode; Registry: PlayerService, CurrencyService,
	              BarricadeService, SentryService, EffectService, RemoteService

	API:
		DefenseService:InitMatch(match) / CleanupMatch(match)
		DefenseService:PurchaseDefense(player, defenseId, position, rotationY) -> Result
		DefenseService:UpgradeDefense(player, defenseUid) -> Result
		DefenseService:PurchaseItem(player, itemId) -> Result
		DefenseService:ValidatePlacement(match, session, definition, position, rotationY) -> (boolean, code, CFrame?)
		DefenseService:GetDefenses(match) -> { Defense }
		DefenseService:GetDefense(match, uid) -> Defense?
		DefenseService:GetDefenseFromPart(match, part) -> Defense?
		DefenseService:GetDefensesInRadius(match, position, radius) -> { Defense }
		DefenseService:DestroyDefense(defense, reason)
		DefenseService:RepairAll(match, fraction) -> number
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local CurrencyId = require(Shared.Constants.CurrencyId)
local DefenseConfig = require(Shared.Config.DefenseConfig)
local LifeState = require(Shared.Constants.LifeState)
local MatchState = require(Shared.Constants.MatchState)
local MathUtil = require(Shared.Utilities.MathUtil)
local Result = require(Shared.Utilities.Result)
local ResultCode = require(Shared.Constants.ResultCode)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)

local DefenseService = {}

local states: { [any]: { Index: { [string]: any } } } = {}

local BUILD_BLOCKED_STATES = {
	[MatchState.Waiting] = true,
	[MatchState.MatchEnding] = true,
	[MatchState.Cleanup] = true,
}

function DefenseService:Init() end

function DefenseService:Start()
	local remotes = Services.RemoteService
	remotes:OnInvoke("RequestPurchaseDefense", function(player: Player, defenseId: string, position: Vector3, rotationY: number)
		return self:PurchaseDefense(player, defenseId, position, rotationY)
	end)
	remotes:OnInvoke("RequestUpgradeDefense", function(player: Player, defenseUid: string)
		return self:UpgradeDefense(player, defenseUid)
	end)
	remotes:OnInvoke("RequestPurchaseItem", function(player: Player, itemId: string)
		return self:PurchaseItem(player, itemId)
	end)
end

function DefenseService:InitMatch(match: any)
	states[match] = { Index = {} }
end

function DefenseService:CleanupMatch(match: any)
	-- The owning services destroy the objects; only the index is dropped here.
	states[match] = nil
end

local function activeSession(player: Player): (any, string?)
	local session = Services.PlayerService:GetSession(player)
	if session == nil or session.Match == nil then
		return nil, ResultCode.NotInMatch
	end
	if BUILD_BLOCKED_STATES[session.Match:GetState()] then
		return nil, ResultCode.InvalidState
	end
	if session.LifeState ~= LifeState.InMatch or not session:IsAlive() then
		return nil, ResultCode.Dead
	end
	return session, nil
end

-- Queries ----------------------------------------------------------------------------------

function DefenseService:GetDefenses(match: any): { any }
	local list = {}
	local state = states[match]
	if state then
		for _, defense in state.Index do
			if defense:IsAlive() then
				table.insert(list, defense)
			end
		end
	end
	return list
end

function DefenseService:GetDefense(match: any, uid: string): any
	local state = states[match]
	return state and state.Index[uid]
end

function DefenseService:GetDefenseFromPart(match: any, part: Instance): any
	local model = part:FindFirstAncestorWhichIsA("Model")
	while model and model:GetAttribute(Attributes.DefenseUid) == nil do
		model = model.Parent and model.Parent:FindFirstAncestorWhichIsA("Model")
	end
	if model == nil then
		return nil
	end
	return self:GetDefense(match, model:GetAttribute(Attributes.DefenseUid))
end

function DefenseService:GetDefensesInRadius(match: any, position: Vector3, radius: number): { any }
	local list = {}
	for _, defense in self:GetDefenses(match) do
		if (defense:GetPosition() - position).Magnitude <= radius + defense.FootprintRadius then
			table.insert(list, defense)
		end
	end
	return list
end

function DefenseService:DestroyDefense(defense: any, reason: string)
	local state = states[defense.Match]
	if state and state.Index[defense.Uid] == defense then
		state.Index[defense.Uid] = nil
	end
	if defense.Removed then
		return
	end
	Services.EffectService:PlayAt(defense.Match, "DefenseDestroyed", defense:GetPosition(), { Reason = reason })
	if defense.Kind == "Sentry" then
		Services.SentryService:Remove(defense)
	else
		Services.BarricadeService:Remove(defense)
	end
end

function DefenseService:RepairAll(match: any, fraction: number): number
	local repaired = 0
	for _, defense in self:GetDefenses(match) do
		if defense:Repair(fraction) > 0 then
			repaired += 1
			Services.EffectService:PlayAt(match, "Repair", defense:GetPosition(), {})
		end
	end
	return repaired
end

-- Placement --------------------------------------------------------------------------------

function DefenseService:ValidatePlacement(match: any, session: any, definition: any, position: Vector3, rotationY: number): (boolean, string, CFrame?)
	local placement = DefenseConfig.Placement
	local arena = match.Arena
	local size: Vector3 = definition.Size

	local fromCenter = MathUtil.FlatDistance(position, arena.Center)
	if fromCenter < placement.InnerRadius or fromCenter > placement.OuterRadius then
		return false, ResultCode.Blocked, nil
	end
	local footprint = math.max(size.X, size.Z) / 2
	local bounds = arena.Bounds
	if position.X - footprint < bounds.MinX or position.X + footprint > bounds.MaxX
		or position.Z - footprint < bounds.MinZ or position.Z + footprint > bounds.MaxZ then
		return false, ResultCode.Blocked, nil
	end

	local playerPosition = session:GetPosition()
	if playerPosition == nil or MathUtil.FlatDistance(playerPosition, position) > placement.MaxPlaceDistance then
		return false, ResultCode.OutOfRange, nil
	end

	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Include
	groundParams.FilterDescendantsInstances = { arena.GroundFolder }
	local hit = Workspace:Raycast(Vector3.new(position.X, position.Y + 20, position.Z), Vector3.new(0, -60, 0), groundParams)
	if hit == nil or math.abs(hit.Position.Y - position.Y) > placement.MaxGroundSnap then
		return false, ResultCode.Blocked, nil
	end
	local floorPart = hit.Instance
	if floorPart:GetAttribute(Attributes.Diggable) ~= true or floorPart:GetAttribute(Attributes.PlotId) ~= nil then
		return false, ResultCode.Blocked, nil
	end

	local rotation = CFrame.Angles(0, math.rad(rotationY), 0)
	local cframe = CFrame.new(hit.Position) * rotation
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = {
		arena.GroundFolder,
		arena.PropsFolder,
		match.Folder:FindFirstChild("Defenses") :: Instance,
		match.Folder:FindFirstChild("Crops") :: Instance,
		match.Core.Model,
	}
	local clearance = placement.Clearance
	-- The box starts just above the floor so the floor itself never counts.
	local boxSize = Vector3.new(size.X + clearance * 2, size.Y - 0.3, size.Z + clearance * 2)
	local boxCFrame = cframe * CFrame.new(0, 0.3 + boxSize.Y / 2, 0)
	local overlaps = Workspace:GetPartBoundsInBox(boxCFrame, boxSize, overlapParams)
	for _, part in overlaps do
		-- Slot markers are thin decals on plots; plots themselves are caught via the
		-- ground folder, so markers would only duplicate that result.
		if part:GetAttribute(Attributes.SlotIndex) == nil then
			return false, ResultCode.Blocked, nil
		end
	end

	local defenses = self:GetDefenses(match)
	if #defenses >= placement.MaxDefensesPerMatch then
		return false, ResultCode.LimitReached, nil
	end
	if definition.Kind == "Sentry" then
		local sentries = 0
		for _, defense in defenses do
			if defense.Kind == "Sentry" then
				sentries += 1
			end
		end
		if sentries >= placement.MaxSentriesPerMatch then
			return false, ResultCode.LimitReached, nil
		end
	end
	return true, ResultCode.Ok, cframe
end

function DefenseService:PurchaseDefense(player: Player, defenseId: string, position: Vector3, rotationY: number)
	local session, problem = activeSession(player)
	if session == nil then
		return Result.Fail(problem :: string)
	end
	local definition = DefenseConfig.Defenses[defenseId]
	if definition == nil then
		return Result.Fail(ResultCode.NotFound)
	end
	local match = session.Match
	local state = states[match]
	if state == nil then
		return Result.Fail(ResultCode.NotInMatch)
	end
	if not Services.CurrencyService:CanAfford(player, CurrencyId.MatchCoins, definition.Cost) then
		return Result.Fail(ResultCode.InsufficientFunds)
	end
	local valid, code, cframe = self:ValidatePlacement(match, session, definition, position, rotationY)
	if not valid or cframe == nil then
		return Result.Fail(code)
	end
	if not Services.CurrencyService:TrySpend(player, CurrencyId.MatchCoins, definition.Cost, "Defense:" .. defenseId) then
		return Result.Fail(ResultCode.InsufficientFunds)
	end

	local onDepleted = function(defense: any)
		self:DestroyDefense(defense, "Destroyed")
	end
	local ok, defenseOrError = pcall(function()
		if definition.Kind == "Sentry" then
			return Services.SentryService:Create(match, definition, cframe, player, onDepleted)
		end
		return Services.BarricadeService:Create(match, definition, cframe, player, onDepleted)
	end)
	if not ok then
		warn(`[DefenseService] failed to build {defenseId}: {defenseOrError}`)
		Services.CurrencyService:Grant(player, CurrencyId.MatchCoins, definition.Cost, "Refund")
		return Result.Fail(ResultCode.ServerError)
	end
	state.Index[defenseOrError.Uid] = defenseOrError
	Services.EffectService:PlayAt(match, "Build", cframe.Position, { DefenseId = defenseId })
	return Result.Ok({ DefenseUid = defenseOrError.Uid })
end

function DefenseService:UpgradeDefense(player: Player, defenseUid: string)
	local session, problem = activeSession(player)
	if session == nil then
		return Result.Fail(problem :: string)
	end
	local defense = self:GetDefense(session.Match, defenseUid)
	if defense == nil or not defense:IsAlive() then
		return Result.Fail(ResultCode.NotFound)
	end
	local upgrade = defense:GetNextUpgrade()
	if upgrade == nil then
		return Result.Fail(ResultCode.MaxLevel)
	end
	local playerPosition = session:GetPosition()
	if playerPosition == nil or (playerPosition - defense:GetPosition()).Magnitude > DefenseConfig.Placement.MaxPlaceDistance then
		return Result.Fail(ResultCode.OutOfRange)
	end
	if not Services.CurrencyService:TrySpend(player, CurrencyId.MatchCoins, upgrade.Cost, "Upgrade:" .. defense.DefenseId) then
		return Result.Fail(ResultCode.InsufficientFunds)
	end
	defense:ApplyUpgrade()
	Services.EffectService:PlayAt(session.Match, "Repair", defense:GetPosition(), {})
	return Result.Ok({ Level = defense.Level })
end

-- Items ----------------------------------------------------------------------------------------

function DefenseService:PurchaseItem(player: Player, itemId: string)
	local session, problem = activeSession(player)
	if session == nil then
		return Result.Fail(problem :: string)
	end
	local item = DefenseConfig.Items[itemId]
	if item == nil then
		return Result.Fail(ResultCode.NotFound)
	end
	local match = session.Match
	local now = os.clock()

	if item.Kind == "Accessory" then
		if session.Accessories[itemId] then
			return Result.Fail(ResultCode.AlreadyOwned)
		end
		if not Services.CurrencyService:TrySpend(player, CurrencyId.MatchCoins, item.Cost, "Accessory:" .. itemId) then
			return Result.Fail(ResultCode.InsufficientFunds)
		end
		session.Accessories[itemId] = true
		session:RecomputeStats()
		return Result.Ok({ ItemId = itemId })
	end

	local readyAt = session.UtilityReadyAt[itemId]
	if readyAt and now < readyAt then
		return Result.Fail(ResultCode.Cooldown)
	end

	if itemId == "HealingTonic" then
		local humanoid = session.Humanoid
		if humanoid == nil or humanoid.Health >= humanoid.MaxHealth then
			return Result.Fail(ResultCode.AlreadyDone)
		end
		if not Services.CurrencyService:TrySpend(player, CurrencyId.MatchCoins, item.Cost, "Utility:" .. itemId) then
			return Result.Fail(ResultCode.InsufficientFunds)
		end
		session:Heal(item.HealAmount)
		Services.EffectService:PlayAt(match, "Heal", session:GetPosition() or match.Arena.Center, {})
	elseif itemId == "RepairKit" then
		local damaged = false
		for _, defense in self:GetDefenses(match) do
			if defense.Health < defense.MaxHealth then
				damaged = true
				break
			end
		end
		if not damaged then
			return Result.Fail(ResultCode.AlreadyDone)
		end
		if not Services.CurrencyService:TrySpend(player, CurrencyId.MatchCoins, item.Cost, "Utility:" .. itemId) then
			return Result.Fail(ResultCode.InsufficientFunds)
		end
		self:RepairAll(match, item.RepairFraction)
	else
		return Result.Fail(ResultCode.NotFound)
	end
	session.UtilityReadyAt[itemId] = now + (item.Cooldown or 0)
	return Result.Ok({ ItemId = itemId })
end

return DefenseService
