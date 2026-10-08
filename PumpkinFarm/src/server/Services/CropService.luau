--!strict
--[[
	CropService
	Path: ServerScriptService.Server.Services.CropService

	Planting, growth, damage and harvesting. Everything is validated server-side:

	Plant(plotId, slotIndex, seedId):
		in a match, alive, match not ending -> plot/slot exist in THIS match's farm ->
		plot is the player's own or shared -> planting cooldown elapsed -> slot empty ->
		character within PlantRange of the slot -> slot not obstructed by a defense
		(spatial box query) -> seed owned -> seed consumed atomically -> crop.
		Planting is slot-based, so "outside the farm" or "inside an object" positions
		simply cannot be expressed by a client.

	Harvest(cropUid):
		crop exists in THIS match -> alive -> ripe -> within HarvestRange -> chest has
		room -> crop removed BEFORE the reward is paid, so a duplicated request finds
		nothing to harvest.

	Plot ownership: on InitMatch every player gets MatchConfig.Farm.PlotsPerPlayer
	plots (PlotOrder, players sorted by UserId); the rest are shared. Owners are
	replicated as PlotOwnerId / PlotOwnerName attributes on the plot and slot parts.
	ReleasePlots (called when a player leaves the match) makes their plots shared.

	One loop ticks growth for every match (CropConfig.TickInterval).

	Dependencies: Crop, CropConfig, MatchConfig, MatchState, Result, ResultCode, Signal;
	              Attributes; Registry: PlayerService, SeedService, UpgradeService,
	              RewardService, EffectService, RemoteService, HarvestChestService

	API:
		CropService:InitMatch(match) / CleanupMatch(match)
		CropService:GetPlotOwner(match, plotId) -> Player?
		CropService:CanPlantOn(match, player, plotId) -> boolean
		CropService:ReleasePlots(match, player)
		CropService:Plant(player, plotId, slotIndex, seedId) -> Result
		CropService:Harvest(player, cropUid) -> Result
		CropService:GetCrops(match) -> { Crop }
		CropService:GetCrop(match, cropUid) -> Crop?
		CropService:GetCropsInRadius(match, position, radius) -> { Crop }
		CropService:DestroyCrop(crop, reason)
		CropService:StealCrop(crop) -> boolean
		CropService:HealAll(match)
		CropService:ForceRipenAll(match)
		CropService.CropRemoved : Signal(match, crop, reason)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local CropConfig = require(Shared.Config.CropConfig)
local LifeState = require(Shared.Constants.LifeState)
local MatchConfig = require(Shared.Config.MatchConfig)
local MatchState = require(Shared.Constants.MatchState)
local Result = require(Shared.Utilities.Result)
local ResultCode = require(Shared.Constants.ResultCode)
local Signal = require(Shared.Classes.Signal)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)
local Crop = require(Server.Classes.Crop)

type SlotState = { PlotId: string, Index: number, Position: Vector3, Crop: any }
type MatchCrops = {
	Slots: { [string]: { [number]: SlotState } },
	Crops: { [string]: any },
	Owners: { [string]: Player },
	NextPlantAt: { [Player]: number },
}

local CropService = {}
CropService.CropRemoved = Signal.new()

local states: { [any]: MatchCrops } = {}

local CLOSED_STATES = {
	[MatchState.MatchEnding] = true,
	[MatchState.Cleanup] = true,
}

function CropService:Init() end

function CropService:Start()
	Services.RemoteService:OnInvoke("RequestPlant", function(player: Player, plotId: string, slotIndex: number, seedId: string)
		return self:Plant(player, plotId, slotIndex, seedId)
	end)
	Services.RemoteService:OnInvoke("RequestHarvest", function(player: Player, cropUid: string)
		return self:Harvest(player, cropUid)
	end)

	task.spawn(function()
		local interval = CropConfig.TickInterval
		while true do
			local dt = task.wait(interval)
			for match, state in states do
				if not CLOSED_STATES[match:GetState()] then
					for _, crop in state.Crops do
						local ok, err = pcall(crop.Update, crop, dt)
						if not ok then
							warn(`[CropService] crop {crop.Uid} update failed: {err}`)
						end
					end
				end
			end
		end
	end)
end

-- Mirrors a plot's owner onto its plot part and slot parts for the client.
local function replicateOwner(match: any, plotId: string, owner: Player?)
	local plot = match.Arena.Plots[plotId]
	if plot == nil then
		return
	end
	local parts = { plot.Part }
	for _, slot in plot.Slots do
		table.insert(parts, slot.Part)
	end
	for _, part in parts do
		if part then
			part:SetAttribute(Attributes.PlotOwnerId, if owner then owner.UserId else 0)
			part:SetAttribute(Attributes.PlotOwnerName, if owner then owner.DisplayName else "")
		end
	end
end

function CropService:InitMatch(match: any)
	local slots = {}
	for plotId, plot in match.Arena.Plots do
		local plotSlots = {}
		for _, slot in plot.Slots do
			plotSlots[slot.Index] = { PlotId = plotId, Index = slot.Index, Position = slot.Position, Crop = nil }
		end
		slots[plotId] = plotSlots
	end
	local state: MatchCrops = { Slots = slots, Crops = {}, Owners = {}, NextPlantAt = {} }
	states[match] = state

	-- Deterministic assignment: players sorted by UserId take plots in PlotOrder.
	local players = {}
	for _, session in match:GetSessions() do
		table.insert(players, session.Player)
	end
	table.sort(players, function(a, b)
		return a.UserId < b.UserId
	end)
	local perPlayer = MatchConfig.Farm.PlotsPerPlayer
	local nextPlot = 1
	for _, player in players do
		for _ = 1, perPlayer do
			local plotId = match.Arena.PlotOrder[nextPlot]
			if plotId == nil then
				break
			end
			state.Owners[plotId] = player
			nextPlot += 1
		end
	end
	for _, plotId in match.Arena.PlotOrder do
		replicateOwner(match, plotId, state.Owners[plotId])
	end
end

function CropService:GetPlotOwner(match: any, plotId: string): Player?
	local state = states[match]
	return state and state.Owners[plotId]
end

function CropService:CanPlantOn(match: any, player: Player, plotId: string): boolean
	local owner = self:GetPlotOwner(match, plotId)
	return owner == nil or owner == player
end

function CropService:ReleasePlots(match: any, player: Player)
	local state = states[match]
	if state == nil then
		return
	end
	state.NextPlantAt[player] = nil
	for plotId, owner in state.Owners do
		if owner == player then
			state.Owners[plotId] = nil
			replicateOwner(match, plotId, nil)
		end
	end
end

function CropService:CleanupMatch(match: any)
	local state = states[match]
	if state == nil then
		return
	end
	states[match] = nil
	for _, crop in state.Crops do
		crop:Destroy()
	end
end

local function sessionContext(player: Player): (any, any, string?)
	local session = Services.PlayerService:GetSession(player)
	if session == nil or session.Match == nil then
		return nil, nil, ResultCode.NotInMatch
	end
	if CLOSED_STATES[session.Match:GetState()] then
		return nil, nil, ResultCode.InvalidState
	end
	if session.LifeState ~= LifeState.InMatch or not session:IsAlive() then
		return nil, nil, ResultCode.Dead
	end
	return session, session.Match, nil
end

-- A defense (or anything solid that is not part of the farm) sitting on the slot
-- blocks planting.
local function isObstructed(match: any, position: Vector3): boolean
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { match.Folder:FindFirstChild("Defenses") :: Instance }
	local parts = Workspace:GetPartBoundsInBox(CFrame.new(position + Vector3.new(0, 1.5, 0)), Vector3.new(3, 3, 3), params)
	return #parts > 0
end

function CropService:Plant(player: Player, plotId: string, slotIndex: number, seedId: string)
	local session, match, problem = sessionContext(player)
	if problem then
		return Result.Fail(problem)
	end
	local state = states[match]
	local definition = CropConfig.Get(seedId)
	if state == nil or definition == nil then
		return Result.Fail(ResultCode.NotFound)
	end
	local plotSlots = state.Slots[plotId]
	local slot = plotSlots and plotSlots[slotIndex]
	if slot == nil then
		return Result.Fail(ResultCode.NotFound)
	end
	if not self:CanPlantOn(match, player, plotId) then
		return Result.Fail(ResultCode.NotYourPlot)
	end
	local now = os.clock()
	if now < (state.NextPlantAt[player] or 0) then
		return Result.Fail(ResultCode.Cooldown)
	end
	if slot.Crop ~= nil then
		return Result.Fail(ResultCode.Occupied)
	end
	local position = session:GetPosition()
	if position == nil or (position - slot.Position).Magnitude > MatchConfig.Interaction.PlantRange then
		return Result.Fail(ResultCode.OutOfRange)
	end
	if isObstructed(match, slot.Position) then
		return Result.Fail(ResultCode.Blocked)
	end
	if not Services.SeedService:ConsumeSeed(player, seedId) then
		return Result.Fail(ResultCode.NotOwned)
	end
	state.NextPlantAt[player] = now + MatchConfig.Interaction.PlantCooldown

	local growthMultiplier = Services.UpgradeService:GetGrowthSpeedMultiplier(player)
	local crop = Crop.new(match, definition, slot, player, growthMultiplier, function(depleted)
		self:DestroyCrop(depleted, "Eaten")
	end)
	slot.Crop = crop
	state.Crops[crop.Uid] = crop
	Services.EffectService:PlayAt(match, "Plant", slot.Position, { CropId = seedId })
	return Result.Ok({ CropUid = crop.Uid })
end

function CropService:Harvest(player: Player, cropUid: string)
	local session, match, problem = sessionContext(player)
	if problem then
		return Result.Fail(problem)
	end
	local state = states[match]
	local crop = state and state.Crops[cropUid]
	if crop == nil or not crop:IsAlive() then
		return Result.Fail(ResultCode.NotFound)
	end
	if not crop:IsRipe() then
		return Result.Fail(ResultCode.NotReady)
	end
	local position = session:GetPosition()
	if position == nil or (position - crop:GetPosition()).Magnitude > MatchConfig.Interaction.HarvestRange then
		return Result.Fail(ResultCode.OutOfRange)
	end
	if not Services.HarvestChestService:CanDeposit(match, crop.CropId, crop.Definition.YieldQuantity) then
		return Result.Fail(ResultCode.ChestFull)
	end
	-- Remove first: a second request for the same uid now fails with NotFound.
	self:DestroyCrop(crop, "Harvested")
	Services.RewardService:OnCropHarvested(match, session, crop)
	Services.EffectService:PlayAt(match, "Harvest", crop:GetPosition(), { CropId = crop.CropId })
	return Result.Ok({ CropId = crop.CropId, Quantity = crop.Definition.YieldQuantity })
end

function CropService:GetCrops(match: any): { any }
	local state = states[match]
	local list = {}
	if state then
		for _, crop in state.Crops do
			table.insert(list, crop)
		end
	end
	return list
end

function CropService:GetCrop(match: any, cropUid: string): any
	local state = states[match]
	return state and state.Crops[cropUid]
end

function CropService:GetCropsInRadius(match: any, position: Vector3, radius: number): { any }
	local list = {}
	local state = states[match]
	if state then
		for _, crop in state.Crops do
			if crop:IsAlive() and (crop:GetPosition() - position).Magnitude <= radius then
				table.insert(list, crop)
			end
		end
	end
	return list
end

function CropService:DestroyCrop(crop: any, reason: string)
	local state = states[crop.Match]
	if state == nil or state.Crops[crop.Uid] ~= crop then
		return
	end
	state.Crops[crop.Uid] = nil
	local slot = state.Slots[crop.PlotId] and state.Slots[crop.PlotId][crop.SlotIndex]
	if slot and slot.Crop == crop then
		slot.Crop = nil
	end
	local match = crop.Match
	if reason == "Eaten" then
		Services.EffectService:PlayAt(match, "CropDestroyed", crop:GetPosition(), { CropId = crop.CropId })
		if crop:IsRipe() or crop.Definition.Rarity == "Rare" or crop.Definition.Rarity == "Epic" then
			match:Notify(`A {crop.Definition.DisplayName} was destroyed!`, "Warning")
		end
	end
	crop:Destroy()
	self.CropRemoved:Fire(match, crop, reason)
end

-- Used by Plague Crows. Returns false for crops that cannot be carried away.
function CropService:StealCrop(crop: any): boolean
	if not crop:IsAlive() or not crop:CanBeStolen() then
		return false
	end
	local match = crop.Match
	Services.EffectService:PlayAt(match, "Steal", crop:GetPosition(), { CropId = crop.CropId })
	match:Notify(`A crow stole a {crop.Definition.DisplayName}! Shoot it down to get it back.`, "Warning")
	self:DestroyCrop(crop, "Stolen")
	return true
end

function CropService:HealAll(match: any)
	for _, crop in self:GetCrops(match) do
		crop:Heal(CropConfig.ContinueHealFraction)
	end
end

function CropService:ForceRipenAll(match: any)
	for _, crop in self:GetCrops(match) do
		crop:ForceRipen()
	end
end

return CropService
