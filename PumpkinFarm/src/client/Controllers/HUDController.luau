--!strict
--[[
	HUDController
	Path: StarterPlayerScripts.Client.Controllers.HUDController

	Main HUD (ScreenGui "MainHUD"):
		top centre   Wave / Day, phase + countdown, Zombies Left, danger level
		under it     current objective and the Great Pumpkin health bar
		bottom left  player health, active effects, Match Coins, Candies, class
		right side   action buttons: Seeds [G], Defenses [B], Chest [C], Heal [H]
		overlay      "knocked out" message while downed
	All values come from replicated attributes (match folder, player, humanoid); timers
	count down locally from PhaseEndsAt.

	API:
		HUDController:SetActionsVisible(visible)
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local ClassConfig = require(Shared.Config.ClassConfig)
local Clock = require(Shared.Utilities.Clock)
local DefenseConfig = require(Shared.Config.DefenseConfig)
local Format = require(Shared.Utilities.Format)
local LifeState = require(Shared.Constants.LifeState)
local MatchState = require(Shared.Constants.MatchState)
local StatusEffectConfig = require(Shared.Config.StatusEffectConfig)

local Client = script:FindFirstAncestor("Client") :: Instance
local ClientState = require(Client.Modules.ClientState)
local Controllers = require(Client.Modules.ControllerRegistry)
local Net = require(Client.Modules.Net)
local Panels = require(Client.Modules.Panels)
local UIKit = require(Client.Modules.UIKit)

local player = Players.LocalPlayer
local Palette = UIKit.Palette

local STATE_TEXT = {
	[MatchState.Waiting] = "Loading the farm",
	[MatchState.Starting] = "Get ready",
	[MatchState.Intermission] = "Intermission",
	[MatchState.PreparingWave] = "Incoming!",
	[MatchState.WaveActive] = "Defend the farm!",
	[MatchState.BossWave] = "BOSS WAVE",
	[MatchState.WaveComplete] = "Wave cleared",
	[MatchState.Extraction] = "Escape Door open",
	[MatchState.ContinuePreparation] = "PREPARATION",
	[MatchState.MatchEnding] = "Match over",
	[MatchState.Cleanup] = "Returning...",
}

local HUDController = {}

local ui: { [string]: any } = {}

local function build()
	local screen = UIKit.Screen("MainHUD", 1)
	ui.Screen = screen

	-- Top centre ------------------------------------------------------------------
	local top = UIKit.Panel({
		Name = "WavePanel",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.new(0.36, 0, 0, 74),
		Parent = screen,
	})
	UIKit.Create("UISizeConstraint", { MinSize = Vector2.new(260, 74), MaxSize = Vector2.new(520, 74), Parent = top })
	ui.WaveLabel = UIKit.Label({
		Name = "Wave",
		Size = UDim2.new(1, -16, 0, 34),
		Position = UDim2.fromOffset(8, 4),
		Font = UIKit.Fonts.Title,
		Text = "WAVE 0",
		MaxTextSize = 30,
		TextColor3 = Palette.Accent,
		Parent = top,
	})
	ui.PhaseLabel = UIKit.Label({
		Name = "Phase",
		Size = UDim2.new(0.6, -8, 0, 26),
		Position = UDim2.new(0, 8, 0, 42),
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Left,
		MaxTextSize = 20,
		Parent = top,
	})
	ui.ZombiesLabel = UIKit.Label({
		Name = "Zombies",
		Size = UDim2.new(0.4, -8, 0, 26),
		Position = UDim2.new(0.6, 0, 0, 42),
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Palette.Bad,
		MaxTextSize = 20,
		Parent = top,
	})
	ui.DangerLabel = UIKit.Label({
		Name = "Danger",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 86),
		Size = UDim2.new(0.3, 0, 0, 22),
		Text = "",
		Visible = false,
		TextColor3 = Palette.Bad,
		Font = UIKit.Fonts.Title,
		MaxTextSize = 20,
		Parent = screen,
	})
	ui.Objective = UIKit.Label({
		Name = "Objective",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 110),
		Size = UDim2.new(0.5, 0, 0, 24),
		Text = "",
		MaxTextSize = 20,
		Parent = screen,
	})
	ui.CoreBar = UIKit.Bar({
		Name = "CoreBar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 138),
		Size = UDim2.new(0.26, 0, 0, 20),
		Color = Palette.PumpkinOrange,
		Text = "🎃 Great Pumpkin",
		MaxTextSize = 16,
		Parent = screen,
	})

	-- Bottom left ---------------------------------------------------------------------
	local stats = UIKit.Panel({
		Name = "PlayerPanel",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -10),
		Size = UDim2.fromOffset(300, 128),
		Parent = screen,
	})
	ui.ClassLabel = UIKit.Label({
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.fromOffset(8, 6),
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UIKit.Fonts.Title,
		MaxTextSize = 20,
		Parent = stats,
	})
	ui.HealthBar = UIKit.Bar({
		Name = "HealthBar",
		Position = UDim2.fromOffset(8, 32),
		Size = UDim2.new(1, -16, 0, 24),
		Color = Palette.Health,
		Parent = stats,
	})
	ui.CoinsLabel = UIKit.Label({
		Size = UDim2.new(0.5, -12, 0, 28),
		Position = UDim2.fromOffset(8, 62),
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Palette.Coin,
		Font = UIKit.Fonts.Title,
		MaxTextSize = 22,
		Parent = stats,
	})
	ui.CandyLabel = UIKit.Label({
		Size = UDim2.new(0.5, -12, 0, 28),
		Position = UDim2.new(0.5, 4, 0, 62),
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Palette.Candy,
		Font = UIKit.Fonts.Title,
		MaxTextSize = 22,
		Parent = stats,
	})
	ui.Effects = UIKit.Create("Frame", {
		Name = "Effects",
		Size = UDim2.new(1, -16, 0, 26),
		Position = UDim2.fromOffset(8, 96),
		BackgroundTransparency = 1,
		Parent = stats,
	}, { UIKit.List(Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Left) })

	-- Right side actions ----------------------------------------------------------------
	local actions = UIKit.Create("Frame", {
		Name = "Actions",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(150, 230),
		BackgroundTransparency = 1,
		Parent = screen,
	}, { UIKit.List(Enum.FillDirection.Vertical, 8) })
	ui.Actions = actions
	local function action(order: number, text: string, color: Color3, onClick: () -> ())
		UIKit.Button({
			Name = text,
			Text = text,
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, 48),
			Color = color,
			OnClick = onClick,
			Parent = actions,
		})
	end
	action(1, "🌱 Seeds [G]", Palette.Good, function()
		Panels.Toggle("ShopUI")
	end)
	action(2, "🧱 Defenses [B]", Palette.Info, function()
		Panels.Toggle("DefenseUI")
	end)
	action(3, "📦 Chest [C]", Palette.Coin, function()
		Panels.Toggle("HarvestUI")
	end)
	action(4, `❤️ Heal {DefenseConfig.Items.HealingTonic.Cost} [H]`, Palette.Bad, function()
		HUDController:UseHeal()
	end)

	ui.Downed = UIKit.Label({
		Name = "Downed",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.new(0.6, 0, 0, 60),
		Text = "KNOCKED OUT\n<font size=\"18\">You will be revived when the wave ends</font>",
		Font = UIKit.Fonts.Title,
		TextColor3 = Palette.Bad,
		MaxTextSize = 40,
		Visible = false,
		Parent = screen,
	})
end

function HUDController:UseHeal()
	task.spawn(function()
		local result = Net:Invoke("RequestPurchaseItem", "HealingTonic")
		Controllers.NotificationController:ShowResult(result, "Healed!")
	end)
end

function HUDController:SetActionsVisible(visible: boolean)
	ui.Actions.Visible = visible
end

local function refreshInMatch()
	local inMatch = ClientState.InMatch()
	ui.Screen.WavePanel.Visible = inMatch
	ui.Objective.Visible = inMatch
	ui.CoreBar.Frame.Visible = inMatch
	ui.Actions.Visible = inMatch
	ui.CoinsLabel.Visible = inMatch
	if not inMatch then
		ui.DangerLabel.Visible = false
	end
end

local function refreshCurrencies()
	local coins = player:GetAttribute(Attributes.MatchCoins)
	ui.CoinsLabel.Text = `🪙 {Format.Commas(coins or 0)}`
	ui.CandyLabel.Text = `🍬 {Format.Commas(player:GetAttribute(Attributes.Candies) or 0)}`
	local classId = player:GetAttribute(Attributes.ClassId)
	local definition = classId and ClassConfig.Get(classId)
	ui.ClassLabel.Text = if definition then `{definition.Icon} {definition.DisplayName}` else ""
end

local function refreshEffects()
	for _, child in ui.Effects:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	local raw = player:GetAttribute(Attributes.Effects)
	if type(raw) ~= "string" then
		return
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or type(decoded) ~= "table" then
		return
	end
	local now = Clock.Now()
	for effectId, expiresAt in decoded do
		local definition = StatusEffectConfig.Get(effectId)
		if definition and expiresAt > now then
			UIKit.Label({
				Size = UDim2.fromOffset(90, 24),
				Text = `{definition.Icon} {definition.DisplayName}`,
				TextColor3 = if definition.IsBuff then Palette.Good else Palette.Warning,
				MaxTextSize = 16,
				Parent = ui.Effects,
			})
		end
	end
end

local function bindHumanoid(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if humanoid == nil then
		return
	end
	local function update()
		ui.HealthBar:Set(humanoid.Health / math.max(1, humanoid.MaxHealth), `{math.ceil(humanoid.Health)} / {math.ceil(humanoid.MaxHealth)}`)
	end
	humanoid.HealthChanged:Connect(update)
	humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(update)
	update()
end

function HUDController:Init()
	build()
end

function HUDController:Start()
	refreshInMatch()
	refreshCurrencies()
	ClientState.MatchChanged:Connect(refreshInMatch)
	for _, name in { Attributes.MatchCoins, Attributes.Candies, Attributes.ClassId } do
		player:GetAttributeChangedSignal(name):Connect(refreshCurrencies)
	end
	player:GetAttributeChangedSignal(Attributes.Effects):Connect(refreshEffects)
	player:GetAttributeChangedSignal(Attributes.LifeState):Connect(function()
		ui.Downed.Visible = player:GetAttribute(Attributes.LifeState) == LifeState.Downed
	end)

	if player.Character then
		task.spawn(bindHumanoid, player.Character)
	end
	player.CharacterAdded:Connect(bindHumanoid)

	local function refreshWave()
		local wave = ClientState.GetMatchAttribute(Attributes.Wave) or 0
		local isBoss = ClientState.GetMatchAttribute(Attributes.IsBossWave) == true
		ui.WaveLabel.Text = if isBoss then `💀 BOSS WAVE {wave}` else `🌙 WAVE {wave}`
		ui.WaveLabel.TextColor3 = if isBoss then Palette.Boss else Palette.Accent
	end
	ClientState.ObserveMatchAttribute(Attributes.Wave, refreshWave)
	ClientState.ObserveMatchAttribute(Attributes.IsBossWave, refreshWave)
	ClientState.ObserveMatchAttribute(Attributes.EnemiesRemaining, function(remaining)
		ui.ZombiesLabel.Text = if remaining and remaining > 0 then `🧟 {remaining} left` else ""
	end)
	ClientState.ObserveMatchAttribute(Attributes.Objective, function(text)
		ui.Objective.Text = text or ""
	end)
	ClientState.ObserveMatchAttribute(Attributes.ContinueLevel, function(level)
		local danger = ClientState.GetMatchAttribute(Attributes.DifficultyMultiplier) or 1
		ui.DangerLabel.Visible = level ~= nil and level > 0
		ui.DangerLabel.Text = `☠ DANGER {Format.Roman(level or 0)} • {Format.Multiplier(danger)}`
	end)
	local function refreshCore()
		local health = ClientState.GetMatchAttribute(Attributes.CoreHealth) or 0
		local maxHealth = ClientState.GetMatchAttribute(Attributes.CoreMaxHealth) or 1
		ui.CoreBar:Set(health / math.max(1, maxHealth), `🎃 Great Pumpkin {Format.Commas(health)}`)
	end
	ClientState.ObserveMatchAttribute(Attributes.CoreHealth, refreshCore)
	ClientState.ObserveMatchAttribute(Attributes.CoreMaxHealth, refreshCore)

	-- Countdown text updates locally; no network traffic per second.
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 0.2 then
			return
		end
		accumulator = 0
		if not ClientState.InMatch() then
			return
		end
		local state = ClientState.GetMatchAttribute(Attributes.State)
		local endsAt = ClientState.GetMatchAttribute(Attributes.PhaseEndsAt) or 0
		local text = STATE_TEXT[state] or ""
		if endsAt > 0 then
			text ..= `  {Format.Countdown(endsAt - Clock.Now())}`
		end
		ui.PhaseLabel.Text = text
		if player:GetAttribute(Attributes.Effects) then
			refreshEffects()
		end
	end)
end

return HUDController
