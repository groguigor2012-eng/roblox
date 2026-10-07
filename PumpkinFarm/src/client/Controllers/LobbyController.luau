--!strict
--[[
	LobbyController
	Path: StarterPlayerScripts.Client.Controllers.LobbyController

	Lobby UI (ScreenGui "LobbyUI"), shown while not in a match:
		* PLAY / LEAVE QUEUE button and live queue countdown (QueueEndsAt/QueueSize)
		* Wardrobe and Upgrades buttons (also reachable through world prompts)
		* persisted settings toggles (music, effects) via RequestUpdateSettings
		* lifetime statistics card
		* a warning when the profile failed to load or is temporary (Studio mock)

	API: none (self-contained)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local Clock = require(Shared.Utilities.Clock)
local Format = require(Shared.Utilities.Format)
local LifeState = require(Shared.Constants.LifeState)

local Client = script:FindFirstAncestor("Client") :: Instance
local ClientState = require(Client.Modules.ClientState)
local Controllers = require(Client.Modules.ControllerRegistry)
local Net = require(Client.Modules.Net)
local Panels = require(Client.Modules.Panels)
local UIKit = require(Client.Modules.UIKit)

local player = Players.LocalPlayer
local Palette = UIKit.Palette

local LobbyController = {}

local ui: { [string]: any } = {}

function LobbyController:Init()
	local screen = UIKit.Screen("LobbyUI", 2)
	ui.Screen = screen

	UIKit.Label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.new(0.6, 0, 0, 56),
		Text = "🎃 PROTECT THE PUMPKIN FARM 🎃",
		Font = UIKit.Fonts.Title,
		TextColor3 = Palette.Accent,
		MaxTextSize = 46,
		Parent = screen,
	})

	ui.Warning = UIKit.Label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 70),
		Size = UDim2.new(0.7, 0, 0, 26),
		Text = "",
		TextColor3 = Palette.Warning,
		MaxTextSize = 20,
		Visible = false,
		Parent = screen,
	})

	local bottom = UIKit.Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -16),
		Size = UDim2.fromOffset(560, 120),
		BackgroundTransparency = 1,
		Parent = screen,
	})
	ui.Play = UIKit.Button({
		Name = "Play",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.fromOffset(260, 64),
		Text = "▶ PLAY",
		Color = Palette.Good,
		MaxTextSize = 34,
		OnClick = function()
			LobbyController:ToggleQueue()
		end,
		Parent = bottom,
	})
	ui.QueueStatus = UIKit.Label({
		Position = UDim2.fromOffset(0, 70),
		Size = UDim2.new(1, 0, 0, 24),
		Text = "",
		MaxTextSize = 20,
		Parent = bottom,
	})
	UIKit.Button({
		Position = UDim2.new(0, 0, 0, 8),
		Size = UDim2.fromOffset(130, 48),
		Text = "👗 Wardrobe",
		Color = Palette.AlienPurple,
		OnClick = function()
			Panels.Toggle("ClassUI")
		end,
		Parent = bottom,
	})
	UIKit.Button({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 8),
		Size = UDim2.fromOffset(130, 48),
		Text = "🍬 Upgrades",
		Color = Palette.Candy,
		OnClick = function()
			Panels.Toggle("UpgradeUI")
		end,
		Parent = bottom,
	})

	local side = UIKit.Panel({
		Name = "Stats",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 110),
		Size = UDim2.fromOffset(240, 250),
		Parent = screen,
	})
	ui.Stats = UIKit.Label({
		Position = UDim2.fromOffset(12, 10),
		Size = UDim2.new(1, -24, 1, -110),
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		MaxTextSize = 18,
		Parent = side,
	})
	local function toggle(order: number, key: string, label: string)
		local button = UIKit.Button({
			Position = UDim2.new(0, 12, 1, -(order * 46)),
			Size = UDim2.new(1, -24, 0, 38),
			Text = label,
			Color = Palette.PanelLight,
			MaxTextSize = 18,
			OnClick = function()
				local profile = ClientState.Profile
				local current = profile and profile.Settings and profile.Settings[key]
				Net:Fire("RequestUpdateSettings", key, not current)
			end,
			Parent = side,
		})
		ui["Toggle" .. key] = button
	end
	toggle(1, "EffectsEnabled", "Effects")
	toggle(2, "MusicEnabled", "Music")
end

function LobbyController:ToggleQueue()
	task.spawn(function()
		local queued = player:GetAttribute(Attributes.Queued) == true
		local result = Net:Invoke(if queued then "RequestLeaveQueue" else "RequestJoinQueue")
		Controllers.NotificationController:ShowResult(result, if queued then "Left the queue." else "Joined the farm queue!")
	end)
end

local function refreshProfile(profile: any)
	if profile == nil then
		return
	end
	local stats = profile.Statistics or {}
	ui.Stats.Text = table.concat({
		"<b>YOUR FARM RECORD</b>",
		`🍬 Candies: {Format.Commas(profile.Candies or 0)}`,
		`🌙 Highest wave: {stats.HighestWave or 0}`,
		`🧟 Zombies: {Format.Commas(stats.TotalKills or 0)}`,
		`🌾 Harvested: {Format.Commas(stats.TotalHarvested or 0)}`,
		`💀 Bosses: {stats.BossesDefeated or 0}`,
		`🚪 Escapes: {stats.MatchesEscaped or 0} / {stats.MatchesPlayed or 0}`,
	}, "\n")
	for _, key in { "MusicEnabled", "EffectsEnabled" } do
		local enabled = profile.Settings and profile.Settings[key] ~= false
		local button = ui["Toggle" .. key]
		button.Text = `{if key == "MusicEnabled" then "🎵 Music" else "✨ Effects"}: {if enabled then "ON" else "OFF"}`
	end
end

local function refreshWarning()
	local status = player:GetAttribute(Attributes.ProfileStatus)
	if status == "Failed" then
		ui.Warning.Text = "⚠ Your save data failed to load. Matches are disabled. Please rejoin."
		ui.Warning.Visible = true
	elseif status == "Temporary" then
		ui.Warning.Text = "Test mode: progress in this server is not saved."
		ui.Warning.Visible = true
	else
		ui.Warning.Visible = false
	end
end

function LobbyController:Start()
	local function refreshVisibility()
		local state = player:GetAttribute(Attributes.LifeState)
		ui.Screen.Enabled = not ClientState.InMatch() and state ~= LifeState.InMatch and state ~= LifeState.Downed
	end
	ClientState.MatchChanged:Connect(refreshVisibility)
	player:GetAttributeChangedSignal(Attributes.LifeState):Connect(refreshVisibility)
	refreshVisibility()

	ClientState.ProfileChanged:Connect(refreshProfile)
	refreshProfile(ClientState.Profile)
	player:GetAttributeChangedSignal(Attributes.ProfileStatus):Connect(refreshWarning)
	refreshWarning()

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 0.25 then
			return
		end
		accumulator = 0
		local queued = player:GetAttribute(Attributes.Queued) == true
		ui.Play.Text = if queued then "✖ LEAVE QUEUE" else "▶ PLAY"
		if queued then
			local endsAt = player:GetAttribute(Attributes.QueueEndsAt) or 0
			local size = player:GetAttribute(Attributes.QueueSize) or 1
			ui.QueueStatus.Text = `Farm starts in {Format.Countdown(endsAt - Clock.Now())} • {size} farmer(s) queued`
		else
			ui.QueueStatus.Text = "Step through the Farm Portal or press PLAY"
		end
	end)
end

return LobbyController
