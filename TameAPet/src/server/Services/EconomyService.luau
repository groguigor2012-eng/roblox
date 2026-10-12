-- Currency and the shop. All prices come from ShopConfig on the server; a purchase deducts
-- and grants in one atomic transaction (Data/Transactions.purchase).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Config.GameConfig)
local RemoteNames = require(ReplicatedStorage.Shared.RemoteNames)
local Format = require(ReplicatedStorage.Shared.Format)
local Transactions = require(ServerScriptService.Data.Transactions)
local Validate = require(ServerScriptService.Security.Validate)

local Codes = RemoteNames.Codes

local EconomyService = {}
EconomyService.Name = "EconomyService"

local Services

-- Server-originated rewards only (hatching, pickups, playtime). Returns the amount added.
function EconomyService.addCurrency(player: Player, amount: number, _reason: string): number
	local data = Services.DataService.getData(player)
	if not data then
		return 0
	end
	local added = Transactions.addCurrency(data, Services.DataService.context(), math.floor(amount))
	if added > 0 then
		Services.DataService.markDirty(player)
	end
	return added
end

function EconomyService.getBalance(player: Player): number
	local data = Services.DataService.getData(player)
	return if data then data.currency else 0
end

local function failureMessage(code: string, details: any?, data: any): string
	if code == Codes.InsufficientFunds and details then
		local missing = details.price - data.currency
		return `You need {Format.commas(missing)} more {GameConfig.CurrencyName}.`
	elseif code == Codes.AlreadyOwned then
		return "You already own that."
	elseif code == Codes.Locked then
		return "Unlock the previous zone first."
	elseif code == Codes.Maxed then
		return "Already at the maximum level."
	elseif code == Codes.NotFound then
		return "That item isn't for sale."
	end
	return "That purchase isn't available right now."
end

local function purchase(player: Player, productId: string)
	local Security = Services.RemoteSecurityService
	local data = Services.DataService.getData(player)
	if not data then
		return Security.fail(Codes.NotReady, "Your data is still loading.")
	end

	local ok, code, details = Transactions.purchase(data, Services.DataService.context(), productId)
	if not ok then
		if code == Codes.NotFound or code == Codes.ConfigError then
			Security.report(player, "Purchase", `unknown or misconfigured product "{productId}"`)
		end
		return Security.fail(code, failureMessage(code, details, data))
	end

	Services.DataService.markDirty(player)
	Services.NotificationService.notify(
		player,
		"success",
		`Purchased {details.product} for {Format.commas(details.price)} {GameConfig.CurrencyName}!`
	)
	if details.kind == "Compass" or details.kind == "ZoneUnlock" then
		Services.CompassService.refresh(player)
	elseif details.kind == "SpeedUpgrade" then
		Services.MountService.refreshStats(player)
	end
	return Security.ok({ balance = data.currency })
end

function EconomyService.init(services)
	Services = services
end

function EconomyService.start()
	Services.RemoteSecurityService.bindFunction(
		"Purchase",
		{ action = "Purchase", args = { Validate.id(48) } },
		purchase
	)

	-- Playtime income.
	task.spawn(function()
		local income = GameConfig.Income
		while true do
			task.wait(income.PlaytimeInterval)
			for _, player in Players:GetPlayers() do
				if Services.PlayerStateService.isReady(player) then
					local added = EconomyService.addCurrency(player, income.PlaytimeAmount, "Playtime")
					if added > 0 then
						Services.NotificationService.notify(player, "coin", `+{added} {GameConfig.CurrencyName} for exploring`)
					end
				end
			end
		end
	end)
end

return EconomyService
