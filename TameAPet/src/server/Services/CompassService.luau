-- Server-side target selection for compasses. Every TargetRefreshInterval each player with an
-- equipped compass gets the nearest eligible active egg (by the authoritative registry, so it
-- works with StreamingEnabled and distant eggs that don't exist on the client). Only changes
-- are sent. When a tracked egg is claimed or expires, affected players are retargeted at once.
--
-- CompassTarget payload:
--   { eggId: string, position: Vector3, tier: string, zoneId: string, compassId: string }
--   or { none: true, reason: "NoCompass" | "NoEggs", compassId: string? }
-- Tracking is navigation only: claiming an egg never trusts anything from this system.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CompassConfig = require(ReplicatedStorage.Config.CompassConfig)
local RarityConfig = require(ReplicatedStorage.Config.RarityConfig)
local Remotes = require(ServerScriptService.Security.Remotes)
local ZoneRegistry = require(ServerScriptService.World.ZoneRegistry)

local CompassService = {}
CompassService.Name = "CompassService"

local Services
-- Last state sent to each player, as a comparable key.
local lastKey: { [Player]: string } = {}
local trackedEgg: { [Player]: string? } = {}

local function findTarget(player: Player)
	local data = Services.DataService.getData(player)
	if not data or data.equippedCompass == "" then
		return nil, "NoCompass", nil
	end
	local compassId = data.equippedCompass
	local compass = CompassConfig.Compasses[compassId]
	if not compass then
		return nil, "NoCompass", nil
	end
	local root = Services.PlayerStateService.getRoot(player)
	if not root then
		return nil, "NoEggs", compassId
	end
	local origin = root.Position
	local minRank = RarityConfig.rank(compass.minTier)
	local best, bestDistance = nil, compass.maxRange
	for _, egg in Services.EggSpawnService.activeEggs() do
		if RarityConfig.rank(egg.kind) >= minRank and ZoneRegistry.isUnlocked(data, egg.zoneId) then
			local distance = (egg.position - origin).Magnitude
			if distance <= bestDistance then
				best, bestDistance = egg, distance
			end
		end
	end
	if not best then
		return nil, "NoEggs", compassId
	end
	return best, nil, compassId
end

local function update(player: Player, force: boolean)
	if not Services.PlayerStateService.isReady(player) then
		return
	end
	local egg, reason, compassId = findTarget(player)
	local key = if egg then `egg:{egg.id}:{compassId}` else `none:{reason}:{compassId or ""}`
	if not force and lastKey[player] == key then
		return
	end
	lastKey[player] = key
	trackedEgg[player] = if egg then egg.id else nil
	if egg then
		Remotes.fire("CompassTarget", player, {
			eggId = egg.id,
			position = egg.position,
			tier = egg.kind,
			zoneId = egg.zoneId,
			compassId = compassId,
		})
	else
		Remotes.fire("CompassTarget", player, { none = true, reason = reason, compassId = compassId })
	end
end

-- Recompute and resend immediately (after equipping, buying a zone pass, etc.).
function CompassService.refresh(player: Player)
	update(player, true)
end

function CompassService.init(services)
	Services = services
end

function CompassService.start()
	Services.EggSpawnService.EggRemoved:Connect(function(eggId)
		for player, tracked in trackedEgg do
			if tracked == eggId then
				update(player, true)
			end
		end
	end)
	Services.PlayerStateService.Ready:Connect(function(player)
		update(player, true)
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastKey[player] = nil
		trackedEgg[player] = nil
	end)

	task.spawn(function()
		local interval = CompassConfig.Tracking.TargetRefreshInterval
		while true do
			task.wait(interval)
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(update, player, false)
				if not ok then
					warn(`[Compass] update failed for {player.Name}: {err}`)
				end
			end
		end
	end)
end

return CompassService
