--!strict
--[[
	StunService
	Path: ServerScriptService.Server.Services.StunService

	Player stuns (Blighted Scarecrow landing). Built on StatusEffectService's
	"Stunned" effect, which already refuses to stack (Stacking = "Ignore") and grants a
	post-stun immunity window, so a pack of scarecrows cannot chain-stun a player.

	Movement is restricted by the server setting WalkSpeed/JumpHeight to 0 (replicated
	Humanoid properties). Because a modified client could ignore that, this service
	also records where the stun started and snaps the character back if it moves more
	than StunMaxDisplacement while stunned.

	Dependencies: StatusEffectConfig; Registry: StatusEffectService

	API:
		StunService:TryStun(session, duration, source) -> boolean
		StunService:IsStunned(session) -> boolean
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StatusEffectConfig = require(ReplicatedStorage.Shared.Config.StatusEffectConfig)

local Server = script:FindFirstAncestor("Server") :: Instance
local Services = require(Server.Registry)

local StunService = {}

local anchors: { [any]: CFrame } = {}

function StunService:Init() end

function StunService:Start()
	task.spawn(function()
		while true do
			task.wait(0.1)
			for session, anchor in anchors do
				local root = session:GetRoot()
				if root == nil or not self:IsStunned(session) then
					anchors[session] = nil
				elseif (root.Position - anchor.Position).Magnitude > StatusEffectConfig.StunMaxDisplacement then
					root.AssemblyLinearVelocity = Vector3.zero
					root.CFrame = anchor
				end
			end
		end
	end)
end

function StunService:TryStun(session: any, duration: number, source: any): boolean
	if session.Kind ~= "Player" or not session:IsAlive() then
		return false
	end
	local applied = Services.StatusEffectService:Apply(session, "Stunned", { Duration = duration, Source = source })
	if applied then
		local root = session:GetRoot()
		if root then
			anchors[session] = root.CFrame
		end
		Services.EffectService:PlayAt(session.Match, "Stun", root and root.Position or Vector3.zero, { Duration = duration })
	end
	return applied
end

function StunService:IsStunned(session: any): boolean
	return Services.StatusEffectService:Has(session, "Stunned")
end

return StunService
