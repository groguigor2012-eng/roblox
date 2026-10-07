--!strict
--[[
	EffectService
	Path: ServerScriptService.Server.Services.EffectService

	Server -> client cosmetic events. The server decides THAT something happened
	(explosion, slash, potion splash, mole dig, stun, damage number); clients render it
	locally in EffectsController. No gameplay state is ever carried by these events, so
	dropping or spoofing them cannot affect outcomes.

	Events are only sent to players in the same match, and positional events are culled
	by NetworkConfig.EffectCullDistance to keep bandwidth flat with many enemies.

	Effect names (each has a renderer in the client EffectsController; enforced by
	tests/static_check.py): BossCrush, BossSweep, Build, CoinPopup, CropDestroyed,
	DamageNumber, Death, DefenseDestroyed, DigIn, DigOut, Explosion, Harvest, Heal,
	HexNova, Hurt, LanternPulse, Leap, Plant, PotionSplash, Projectile, Repair,
	SentryBolt, Shockwave, Slash, Steal, Stun, Summon, Whirl

	Dependencies: NetworkConfig; Registry: RemoteService

	API:
		EffectService:Play(match, effectName, params)                 -- everyone in match
		EffectService:PlayAt(match, effectName, position, params?)    -- culled by distance
		EffectService:PlayFor(player, effectName, params)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkConfig = require(ReplicatedStorage.Shared.Config.NetworkConfig)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)

local EffectService = {}

function EffectService:Init() end

function EffectService:Play(match: any, effectName: string, params: { [string]: any })
	if match == nil then
		return
	end
	Services.RemoteService:FireClients("Effect", match:GetPlayers(), effectName, params)
end

function EffectService:PlayAt(match: any, effectName: string, position: Vector3, params: { [string]: any }?)
	if match == nil then
		return
	end
	local payload = params or {}
	payload.Position = position
	local cull = NetworkConfig.EffectCullDistance
	local recipients = {}
	for _, session in match:GetSessions() do
		local playerPosition = session:GetPosition()
		if playerPosition == nil or (playerPosition - position).Magnitude <= cull then
			table.insert(recipients, session.Player)
		end
	end
	Services.RemoteService:FireClients("Effect", recipients, effectName, payload)
end

function EffectService:PlayFor(player: Player, effectName: string, params: { [string]: any })
	Services.RemoteService:FireClient("Effect", player, effectName, params)
end

return EffectService
