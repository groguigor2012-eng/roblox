--!strict
--[[
	BossBarController
	Path: StarterPlayerScripts.Client.Controllers.BossBarController

	ScreenGui "BossUI": the Cursed Harvester's bar while BossActive is true on the match
	folder: name, health bar, percentage, aura radius indicator, and a flashing ENRAGED
	warning below the enrage threshold.

	API: none (self-contained)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local Format = require(Shared.Utilities.Format)

local Client = script:FindFirstAncestor("Client") :: Instance
local ClientState = require(Client.Modules.ClientState)
local UIKit = require(Client.Modules.UIKit)

local Palette = UIKit.Palette

local BossBarController = {}

local ui: { [string]: any } = {}

function BossBarController:Init()
	local screen = UIKit.Screen("BossUI", 4)
	local frame = UIKit.Panel({
		Name = "BossPanel",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 166),
		Size = UDim2.new(0.5, 0, 0, 78),
		BackgroundColor3 = Color3.fromRGB(50, 10, 20),
		Visible = false,
		Parent = screen,
	})
	UIKit.Create("UISizeConstraint", { MinSize = Vector2.new(300, 78), MaxSize = Vector2.new(700, 78), Parent = frame })
	ui.Frame = frame
	ui.Name = UIKit.Label({
		Position = UDim2.fromOffset(12, 4),
		Size = UDim2.new(0.7, -12, 0, 26),
		Text = "",
		Font = UIKit.Fonts.Title,
		TextColor3 = Palette.Boss,
		TextXAlignment = Enum.TextXAlignment.Left,
		MaxTextSize = 24,
		Parent = frame,
	})
	ui.Aura = UIKit.Label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 4),
		Size = UDim2.new(0.3, 0, 0, 26),
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Palette.Warning,
		MaxTextSize = 16,
		Parent = frame,
	})
	ui.Bar = UIKit.Bar({
		Position = UDim2.fromOffset(12, 34),
		Size = UDim2.new(1, -24, 0, 30),
		Color = Palette.Boss,
		MaxTextSize = 18,
		Parent = frame,
	})
end

local function refresh()
	local active = ClientState.GetMatchAttribute(Attributes.BossActive) == true
	ui.Frame.Visible = active
	if not active then
		return
	end
	local health = ClientState.GetMatchAttribute(Attributes.BossHealth) or 0
	local maxHealth = ClientState.GetMatchAttribute(Attributes.BossMaxHealth) or 1
	local fraction = health / math.max(1, maxHealth)
	ui.Name.Text = `💀 {ClientState.GetMatchAttribute(Attributes.BossName) or "Boss"}`
	ui.Aura.Text = `🔥 Aura {ClientState.GetMatchAttribute(Attributes.BossAuraRadius) or 0} studs`
	ui.Bar:Set(fraction, `{Format.Commas(health)} / {Format.Commas(maxHealth)}  ({Format.Percent(fraction)})`)
end

function BossBarController:Start()
	for _, name in {
		Attributes.BossActive,
		Attributes.BossHealth,
		Attributes.BossMaxHealth,
		Attributes.BossName,
		Attributes.BossAuraRadius,
	} do
		ClientState.ObserveMatchAttribute(name, refresh)
	end
	-- Enraged warning pulses the bar colour.
	RunService.Heartbeat:Connect(function()
		if not ui.Frame.Visible then
			return
		end
		local enraged = ClientState.GetMatchAttribute(Attributes.BossEnraged) == true
		if enraged then
			local pulse = (math.sin(os.clock() * 8) + 1) / 2
			ui.Bar.Fill.BackgroundColor3 = Palette.Boss:Lerp(Palette.Warning, pulse)
			ui.Name.Text = `💀 {ClientState.GetMatchAttribute(Attributes.BossName) or "Boss"} — ENRAGED!`
		else
			ui.Bar.Fill.BackgroundColor3 = Palette.Boss
		end
	end)
end

return BossBarController
