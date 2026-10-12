-- Tracks whether each player may interact with gameplay (profile loaded) and offers safe
-- accessors for their character. Nothing gameplay-related is accepted from a player until
-- `isReady` is true.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Signal)

local PlayerStateService = {}
PlayerStateService.Name = "PlayerStateService"

PlayerStateService.Ready = Signal.new() -- (player)
PlayerStateService.Removing = Signal.new() -- (player)

local Services
local ready: { [Player]: boolean } = {}

function PlayerStateService.isReady(player: Player): boolean
	return ready[player] == true and player.Parent == Players
end

function PlayerStateService.getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return humanoid
end

-- HumanoidRootPart of a living character, or nil.
function PlayerStateService.getRoot(player: Player): BasePart?
	if not PlayerStateService.getHumanoid(player) then
		return nil
	end
	local root = (player.Character :: Model):FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

function PlayerStateService.init(services)
	Services = services
end

function PlayerStateService.start()
	Services.DataService.ProfileLoaded:Connect(function(player)
		ready[player] = true
		PlayerStateService.Ready:Fire(player)
	end)
	Services.DataService.ProfileReleasing:Connect(function(player)
		ready[player] = nil
	end)
	Players.PlayerRemoving:Connect(function(player)
		ready[player] = nil
		PlayerStateService.Removing:Fire(player)
	end)
end

return PlayerStateService
