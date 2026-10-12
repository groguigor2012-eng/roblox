-- Sends toast notifications to clients. Identical messages to the same player within a short
-- window are dropped so rate-limited or repeated actions can't spam the screen.
--
-- Notify payload: { kind: "info" | "success" | "error" | "rare" | "coin", text: string, rarity: string? }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local UIConfig = require(ReplicatedStorage.Config.UIConfig)
local Remotes = require(ServerScriptService.Security.Remotes)

local NotificationService = {}
NotificationService.Name = "NotificationService"

local recent: { [Player]: { [string]: number } } = {}

function NotificationService.notify(player: Player, kind: string, text: string, rarity: string?)
	local now = os.clock()
	local perPlayer = recent[player]
	if not perPlayer then
		perPlayer = {}
		recent[player] = perPlayer
	end
	local last = perPlayer[text]
	if last and now - last < UIConfig.Notifications.DuplicateWindow then
		return
	end
	perPlayer[text] = now
	Remotes.fire("Notify", player, { kind = kind, text = text, rarity = rarity })
end

function NotificationService.broadcast(kind: string, text: string, rarity: string?)
	Remotes.fireAll("Notify", { kind = kind, text = text, rarity = rarity })
end

function NotificationService.init(_services) end

function NotificationService.start()
	Players.PlayerRemoving:Connect(function(player)
		recent[player] = nil
	end)
	-- Forget old dedupe entries so the table can't grow without bound.
	task.spawn(function()
		while true do
			task.wait(30)
			local cutoff = os.clock() - 10
			for _, perPlayer in recent do
				for text, at in perPlayer do
					if at < cutoff then
						perPlayer[text] = nil
					end
				end
			end
		end
	end)
end

return NotificationService
