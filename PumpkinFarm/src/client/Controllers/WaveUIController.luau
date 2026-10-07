--!strict
--[[
	WaveUIController
	Path: StarterPlayerScripts.Client.Controllers.WaveUIController

	Big centre-screen moments (ScreenGui "BannerUI"):
		* wave incoming / boss incoming / wave cleared / boss defeated banners
		* the Continue PREPARATION countdown (30, 29, 28 ...) with the danger escalation
		  readout while the match is in ContinuePreparation
		* the end-of-match results card (lost / escaped) with wave reached and payout
	Driven by MatchEvent remotes plus match-folder attributes.

	API:
		WaveUIController:ShowBanner(title, subtitle?, color?, duration?)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local Clock = require(Shared.Utilities.Clock)
local Format = require(Shared.Utilities.Format)
local MatchState = require(Shared.Constants.MatchState)

local Client = script:FindFirstAncestor("Client") :: Instance
local ClientState = require(Client.Modules.ClientState)
local Controllers = require(Client.Modules.ControllerRegistry)
local Net = require(Client.Modules.Net)
local UIKit = require(Client.Modules.UIKit)

local Palette = UIKit.Palette

local WaveUIController = {}

local screen: ScreenGui
local banner: Frame
local bannerTitle: TextLabel
local bannerSubtitle: TextLabel
local prep: Frame
local prepCount: TextLabel
local prepDanger: TextLabel
local results: Frame
local resultsTitle: TextLabel
local resultsBody: TextLabel
local bannerToken = 0
local lastCountdown = -1

function WaveUIController:Init()
	screen = UIKit.Screen("BannerUI", 5)

	banner = UIKit.Create("Frame", {
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.3),
		Size = UDim2.new(0.7, 0, 0, 110),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = screen,
	})
	bannerTitle = UIKit.Label({
		Size = UDim2.new(1, 0, 0, 70),
		Font = UIKit.Fonts.Title,
		MaxTextSize = 64,
		Text = "",
		Parent = banner,
	})
	bannerSubtitle = UIKit.Label({
		Position = UDim2.fromOffset(0, 72),
		Size = UDim2.new(1, 0, 0, 34),
		MaxTextSize = 26,
		Text = "",
		Parent = banner,
	})

	prep = UIKit.Create("Frame", {
		Name = "Preparation",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.36),
		Size = UDim2.new(0.6, 0, 0, 200),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = screen,
	})
	UIKit.Label({
		Size = UDim2.new(1, 0, 0, 50),
		Font = UIKit.Fonts.Title,
		Text = "PREPARATION",
		TextColor3 = Palette.Warning,
		MaxTextSize = 48,
		Parent = prep,
	})
	prepCount = UIKit.Label({
		Position = UDim2.fromOffset(0, 50),
		Size = UDim2.new(1, 0, 0, 100),
		Font = UIKit.Fonts.Title,
		Text = "30",
		MaxTextSize = 96,
		Parent = prep,
	})
	prepDanger = UIKit.Label({
		Position = UDim2.fromOffset(0, 150),
		Size = UDim2.new(1, 0, 0, 40),
		Text = "",
		TextColor3 = Palette.Bad,
		Font = UIKit.Fonts.Title,
		MaxTextSize = 28,
		Parent = prep,
	})

	results = UIKit.Panel({
		Name = "Results",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(420, 240),
		Visible = false,
		Parent = screen,
	})
	resultsTitle = UIKit.Label({
		Position = UDim2.fromOffset(16, 12),
		Size = UDim2.new(1, -32, 0, 56),
		Font = UIKit.Fonts.Title,
		Text = "",
		MaxTextSize = 44,
		Parent = results,
	})
	resultsBody = UIKit.Label({
		Position = UDim2.fromOffset(16, 72),
		Size = UDim2.new(1, -32, 0, 110),
		Text = "",
		MaxTextSize = 22,
		Parent = results,
	})
	UIKit.Button({
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.fromOffset(180, 44),
		Text = "OK",
		OnClick = function()
			results.Visible = false
		end,
		Parent = results,
	})
end

function WaveUIController:ShowBanner(title: string, subtitle: string?, color: Color3?, duration: number?)
	bannerToken += 1
	local token = bannerToken
	bannerTitle.Text = title
	bannerTitle.TextColor3 = color or Palette.Accent
	bannerSubtitle.Text = subtitle or ""
	banner.Visible = true
	banner.Size = UDim2.new(0.5, 0, 0, 80)
	UIKit.Tween(banner, { Size = UDim2.new(0.7, 0, 0, 110) }, 0.25, Enum.EasingStyle.Back)
	task.delay(duration or 3, function()
		if token == bannerToken then
			banner.Visible = false
		end
	end)
end

local function showResults(title: string, color: Color3, body: string)
	resultsTitle.Text = title
	resultsTitle.TextColor3 = color
	resultsBody.Text = body
	results.Visible = true
end

local function onMatchEvent(eventName: string, data: any)
	data = data or {}
	if eventName == "WaveIncoming" then
		WaveUIController:ShowBanner(`WAVE {data.Wave}`, "The zombies are coming!", Palette.Accent, 3)
	elseif eventName == "BossIncoming" then
		WaveUIController:ShowBanner("☠ THE CURSED HARVESTER ☠", `Boss wave {data.Wave}: protect the crops!`, Palette.Boss, 4)
	elseif eventName == "WaveCompleted" then
		WaveUIController:ShowBanner(`WAVE {data.Wave} CLEARED`, "Harvest, rebuild and restock!", Palette.Good, 3)
	elseif eventName == "BossDefeated" then
		WaveUIController:ShowBanner("BOSS DEFEATED!", `Cursed Core added to the chest (+{Format.Commas(data.ChestValue or 0)})`, Palette.Good, 5)
	elseif eventName == "ExtractionOpened" then
		WaveUIController:ShowBanner("THE ESCAPE DOOR IS OPEN", "Escape with your harvest, or Continue for more...", Palette.AlienPurple, 4)
	elseif eventName == "ShopRestocked" then
		Controllers.NotificationController:Notify("🌱 The Seed Shop restocked!", "Info", 3)
	elseif eventName == "Escaped" then
		showResults("ESCAPED!", Palette.Good, `You made it out after wave {data.Wave or 0}.\n+{Format.Commas(data.Candies or 0)} 🍬 Candies banked forever.`)
	elseif eventName == "MatchEnded" then
		if data.Lost then
			showResults("FARM LOST", Palette.Bad, `You reached wave {data.Wave or 0}.\nThe Harvest Chest was lost. Escape earlier next time!`)
		elseif data.Reason == "Extracted" then
			WaveUIController:ShowBanner("EVERYONE ESCAPED", "Returning to the lobby...", Palette.Good, 4)
		end
	end
end

function WaveUIController:Start()
	Net:On("MatchEvent", onMatchEvent)

	RunService.Heartbeat:Connect(function()
		local state = ClientState.GetMatchAttribute(Attributes.State)
		if state ~= MatchState.ContinuePreparation then
			prep.Visible = false
			lastCountdown = -1
			return
		end
		prep.Visible = true
		local endsAt = ClientState.GetMatchAttribute(Attributes.PhaseEndsAt) or 0
		local remaining = math.max(0, math.ceil(endsAt - Clock.Now()))
		if remaining ~= lastCountdown then
			lastCountdown = remaining
			prepCount.Text = tostring(remaining)
			prepCount.TextColor3 = if remaining <= 5 then Palette.Bad else Palette.Text
			if remaining <= 5 and remaining > 0 then
				Controllers.AudioController:Play("Countdown")
			end
			local level = ClientState.GetMatchAttribute(Attributes.ContinueLevel) or 0
			local danger = ClientState.GetMatchAttribute(Attributes.DifficultyMultiplier) or 1
			prepDanger.Text = `DANGER LEVEL {Format.Roman(level)} • Zombies {Format.Multiplier(danger)} health`
		end
	end)
end

return WaveUIController
