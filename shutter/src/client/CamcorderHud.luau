--!strict
-- CamcorderHud (client): the analog viewfinder. Purely visual; it reads server-owned
-- attributes and never decides anything.
--
--   * Always on: a small battery meter (bottom-left).
--   * While filming: REC dot, timecode, date stamp, corner brackets, scanlines, vignette,
--     colour grading, interference bars that grow as the Watcher gets close, and a
--     "SUBJECT HELD" readout while you are freezing it.
--   * Caught: a short full-screen jumpscare.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shutter"):WaitForChild("Config"))

local CAM = Config.Camcorder

local player = Players.LocalPlayer

local CamcorderHud = {}

local FONT = Enum.Font.Code
local HUD_WHITE = Color3.fromRGB(235, 240, 230)
local REC_RED = Color3.fromRGB(230, 40, 40)
local LOW_RED = Color3.fromRGB(240, 70, 60)
local BAR_GREEN = Color3.fromRGB(150, 230, 140)
local INTERFERENCE_BARS = 7
local SCANLINES = 48

local gui: ScreenGui
local viewfinder: Frame
local recDot: Frame
local timecodeLabel: TextLabel
local dateLabel: TextLabel
local heldLabel: TextLabel
local lowBatteryLabel: TextLabel
local batteryFill: Frame
local batteryText: TextLabel
local interference: { Frame } = {}
local caughtFrame: Frame
local caughtText: TextLabel
local colorCorrection: ColorCorrectionEffect
local blur: BlurEffect

local filming = false
local filmStartedAt = 0
local interferenceLevel = 0
local held = false
local rng = Random.new()

-- Battery prediction between server updates (display only).
local serverBattery = CAM.MAX_BATTERY
local serverBatteryAt = 0
local loweredAt = -math.huge

local function label(parent: Instance, name: string, text: string, size: UDim2, position: UDim2, anchor: Vector2): TextLabel
	local text_ = Instance.new("TextLabel")
	text_.Name = name
	text_.BackgroundTransparency = 1
	text_.Font = FONT
	text_.Text = text
	text_.TextColor3 = HUD_WHITE
	text_.TextScaled = true
	text_.TextStrokeTransparency = 0.6
	text_.Size = size
	text_.Position = position
	text_.AnchorPoint = anchor
	text_.Parent = parent
	return text_
end

local function box(parent: Instance, name: string, size: UDim2, position: UDim2, color: Color3, transparency: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
	frame.Size = size
	frame.Position = position
	frame.Parent = parent
	return frame
end

local function cornerBracket(parent: Instance, anchor: Vector2, position: UDim2)
	local holder = Instance.new("Frame")
	holder.Name = "Bracket"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(46, 46)
	holder.AnchorPoint = anchor
	holder.Position = position
	holder.Parent = parent
	-- Horizontal and vertical strokes hugging the corner given by `anchor`.
	box(holder, "H", UDim2.new(1, 0, 0, 3), UDim2.fromScale(0, anchor.Y), HUD_WHITE, 0.1).AnchorPoint = Vector2.new(0, anchor.Y)
	box(holder, "V", UDim2.new(0, 3, 1, 0), UDim2.fromScale(anchor.X, 0), HUD_WHITE, 0.1).AnchorPoint = Vector2.new(anchor.X, 0)
end

local function edgeShade(parent: Instance, name: string, size: UDim2, position: UDim2, anchor: Vector2, rotation: number)
	local shade = box(parent, name, size, position, Color3.new(0, 0, 0), 0)
	shade.AnchorPoint = anchor
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = shade
end

local function build()
	local playerGui = player:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "ShutterHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 10
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Viewfinder (filming only) ------------------------------------------------------
	viewfinder = Instance.new("Frame")
	viewfinder.Name = "Viewfinder"
	viewfinder.BackgroundTransparency = 1
	viewfinder.Size = UDim2.fromScale(1, 1)
	viewfinder.Visible = false
	viewfinder.Parent = gui

	edgeShade(viewfinder, "VignetteTop", UDim2.fromScale(1, 0.22), UDim2.fromScale(0, 0), Vector2.zero, 90)
	edgeShade(viewfinder, "VignetteBottom", UDim2.fromScale(1, 0.22), UDim2.fromScale(0, 1), Vector2.new(0, 1), -90)
	edgeShade(viewfinder, "VignetteLeft", UDim2.fromScale(0.16, 1), UDim2.fromScale(0, 0), Vector2.zero, 0)
	edgeShade(viewfinder, "VignetteRight", UDim2.fromScale(0.16, 1), UDim2.fromScale(1, 0), Vector2.new(1, 0), 180)

	local scanlines = Instance.new("Frame")
	scanlines.Name = "Scanlines"
	scanlines.BackgroundTransparency = 1
	scanlines.Size = UDim2.fromScale(1, 1)
	scanlines.Parent = viewfinder
	for i = 0, SCANLINES - 1 do
		box(scanlines, "Line", UDim2.new(1, 0, 0, 1), UDim2.fromScale(0, i / SCANLINES), Color3.new(0, 0, 0), 0.82)
	end

	for i = 1, INTERFERENCE_BARS do
		local bar = box(viewfinder, "Interference" .. i, UDim2.new(1, 0, 0, 2), UDim2.fromScale(0, 0), Color3.new(1, 1, 1), 1)
		bar.ZIndex = 3
		table.insert(interference, bar)
	end

	local margin = 28
	cornerBracket(viewfinder, Vector2.new(0, 0), UDim2.fromOffset(margin, margin))
	cornerBracket(viewfinder, Vector2.new(1, 0), UDim2.new(1, -margin, 0, margin))
	cornerBracket(viewfinder, Vector2.new(0, 1), UDim2.new(0, margin, 1, -margin))
	cornerBracket(viewfinder, Vector2.new(1, 1), UDim2.new(1, -margin, 1, -margin))

	recDot = box(viewfinder, "RecDot", UDim2.fromOffset(16, 16), UDim2.fromOffset(margin + 26, margin + 22), REC_RED, 0)
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = recDot
	label(viewfinder, "Rec", "REC", UDim2.fromOffset(60, 22), UDim2.fromOffset(margin + 48, margin + 19), Vector2.zero).TextXAlignment =
		Enum.TextXAlignment.Left
	timecodeLabel = label(viewfinder, "Timecode", "00:00:00:00", UDim2.fromOffset(170, 22), UDim2.new(1, -margin - 26, 0, margin + 19), Vector2.new(1, 0))
	timecodeLabel.TextXAlignment = Enum.TextXAlignment.Right
	dateLabel = label(viewfinder, "Date", "", UDim2.fromOffset(220, 22), UDim2.new(1, -margin - 26, 1, -margin - 19), Vector2.new(1, 1))
	dateLabel.TextXAlignment = Enum.TextXAlignment.Right
	label(viewfinder, "Mode", "SP  ▶", UDim2.fromOffset(80, 20), UDim2.new(0, margin + 26, 0, margin + 48), Vector2.zero).TextXAlignment =
		Enum.TextXAlignment.Left

	-- Centre reticle
	box(viewfinder, "ReticleH", UDim2.fromOffset(18, 2), UDim2.fromScale(0.5, 0.5), HUD_WHITE, 0.35).AnchorPoint = Vector2.new(0.5, 0.5)
	box(viewfinder, "ReticleV", UDim2.fromOffset(2, 18), UDim2.fromScale(0.5, 0.5), HUD_WHITE, 0.35).AnchorPoint = Vector2.new(0.5, 0.5)

	heldLabel = label(viewfinder, "Held", "[ SUBJECT HELD ]", UDim2.fromOffset(260, 24), UDim2.new(0.5, 0, 0.5, 40), Vector2.new(0.5, 0))
	heldLabel.TextColor3 = REC_RED
	heldLabel.Visible = false

	lowBatteryLabel = label(viewfinder, "LowBattery", "LOW BATTERY", UDim2.fromOffset(200, 24), UDim2.new(0.5, 0, 1, -margin - 22), Vector2.new(0.5, 1))
	lowBatteryLabel.TextColor3 = LOW_RED
	lowBatteryLabel.Visible = false

	-- Battery meter (always visible) ------------------------------------------------------------
	local battery = Instance.new("Frame")
	battery.Name = "Battery"
	battery.BackgroundTransparency = 1
	battery.AnchorPoint = Vector2.new(0, 1)
	battery.Position = UDim2.new(0, margin + 26, 1, -margin - 18)
	battery.Size = UDim2.fromOffset(150, 22)
	battery.Parent = gui

	local shell = box(battery, "Shell", UDim2.fromOffset(60, 22), UDim2.fromScale(0, 0), Color3.new(0, 0, 0), 0.6)
	local stroke = Instance.new("UIStroke")
	stroke.Color = HUD_WHITE
	stroke.Thickness = 2
	stroke.Parent = shell
	box(battery, "Tip", UDim2.fromOffset(4, 10), UDim2.fromOffset(62, 6), HUD_WHITE, 0)
	batteryFill = box(shell, "Fill", UDim2.new(1, -6, 1, -6), UDim2.fromOffset(3, 3), BAR_GREEN, 0)
	batteryText = label(battery, "Percent", "100%", UDim2.fromOffset(70, 22), UDim2.fromOffset(74, 0), Vector2.zero)
	batteryText.TextXAlignment = Enum.TextXAlignment.Left

	-- Caught overlay ---------------------------------------------------------------------------
	caughtFrame = box(gui, "Caught", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), Color3.new(0, 0, 0), 1)
	caughtFrame.ZIndex = 20
	caughtFrame.Visible = false
	caughtText = label(caughtFrame, "Message", "YOU LOOKED AWAY", UDim2.fromScale(0.6, 0.08), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	caughtText.ZIndex = 21
	caughtText.TextColor3 = REC_RED
	caughtText.TextTransparency = 1

	gui.Parent = playerGui

	-- Colour grading lives in Lighting but is created by this LocalScript, so only this
	-- client has it.
	colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.Name = "ShutterCamcorderGrade"
	colorCorrection.Enabled = false
	colorCorrection.Saturation = -0.45
	colorCorrection.Contrast = 0.18
	colorCorrection.Brightness = 0.03
	colorCorrection.TintColor = Color3.fromRGB(222, 255, 226)
	colorCorrection.Parent = Lighting

	blur = Instance.new("BlurEffect")
	blur.Name = "ShutterCamcorderBlur"
	blur.Enabled = false
	blur.Size = 2
	blur.Parent = Lighting
end

local function formatTimecode(seconds: number): string
	local frames = math.floor((seconds % 1) * 30)
	local whole = math.floor(seconds)
	return string.format("%02d:%02d:%02d:%02d", whole // 3600, (whole // 60) % 60, whole % 60, frames)
end

local function predictedBattery(now: number): number
	local elapsed = now - serverBatteryAt
	local value = serverBattery
	if filming then
		value -= CAM.DRAIN_PER_SECOND * elapsed
	else
		local rechargeStart = math.max(serverBatteryAt, loweredAt + CAM.RECHARGE_DELAY)
		if now > rechargeStart then
			value += CAM.RECHARGE_PER_SECOND * (now - rechargeStart)
		end
	end
	return math.clamp(value, 0, CAM.MAX_BATTERY)
end

local function render()
	local now = os.clock()

	-- Battery
	local battery = predictedBattery(now)
	local fraction = battery / CAM.MAX_BATTERY
	batteryFill.Size = UDim2.new(fraction, -6 * fraction, 1, -6)
	local low = fraction <= 0.2
	batteryFill.BackgroundColor3 = if low then LOW_RED else BAR_GREEN
	batteryText.Text = string.format("%d%%", math.floor(battery + 0.5))

	if not filming then
		return
	end

	local blinkOn = (now * 2) % 2 < 1.2
	recDot.Visible = blinkOn
	timecodeLabel.Text = formatTimecode(now - filmStartedAt)
	lowBatteryLabel.Visible = low and blinkOn
	heldLabel.Visible = held and (now * 4) % 2 < 1.4

	-- Interference: more, brighter, thicker bars as the Watcher closes in.
	local level = interferenceLevel
	for i, bar in interference do
		if level > 0.02 and rng:NextNumber() < 0.35 + level * 0.6 then
			bar.Position = UDim2.fromScale(0, rng:NextNumber())
			bar.Size = UDim2.new(1, 0, 0, math.floor(1 + level * rng:NextNumber(2, 14)))
			bar.BackgroundTransparency = 1 - math.clamp(level * rng:NextNumber(0.25, 0.85), 0, 0.9)
		else
			bar.BackgroundTransparency = 1
		end
		bar.Visible = i <= math.ceil(level * INTERFERENCE_BARS)
	end
	-- Picture jitter at high interference.
	local jitter = if level > 0.5 then (level - 0.5) * 8 else 0
	viewfinder.Position = UDim2.fromOffset(rng:NextNumber(-jitter, jitter), rng:NextNumber(-jitter, jitter))
	colorCorrection.Saturation = -0.45 - level * 0.4
	colorCorrection.Contrast = 0.18 + level * 0.25
	blur.Size = 2 + level * 6
end

local function onBatteryAttribute()
	local value = player:GetAttribute(Config.Attributes.Battery)
	if typeof(value) == "number" then
		serverBattery = value
		serverBatteryAt = os.clock()
	end
end

function CamcorderHud.start()
	build()
	-- Analog date stamp: today's month/day/time, but the year is always 1996.
	local now = DateTime.now()
	dateLabel.Text = string.upper(now:FormatLocalTime("MMM DD", "en-us") .. " 1996  " .. now:FormatLocalTime("hh:mm A", "en-us"))
	onBatteryAttribute()
	player:GetAttributeChangedSignal(Config.Attributes.Battery):Connect(onBatteryAttribute)
	RunService.RenderStepped:Connect(render)
end

function CamcorderHud.setFilming(isFilming: boolean)
	if filming == isFilming then
		return
	end
	filming = isFilming
	viewfinder.Visible = isFilming
	colorCorrection.Enabled = isFilming
	blur.Enabled = isFilming
	-- Re-anchor the prediction at the moment the state flipped.
	serverBattery = predictedBattery(os.clock())
	serverBatteryAt = os.clock()
	if isFilming then
		filmStartedAt = os.clock()
	else
		loweredAt = os.clock()
		held = false
		heldLabel.Visible = false
	end
end

-- 0..1, driven by WatcherFX
function CamcorderHud.setInterference(level: number)
	interferenceLevel = math.clamp(level, 0, 1)
end

function CamcorderHud.setHeld(isHeld: boolean)
	held = isHeld
end

function CamcorderHud.playCaught()
	caughtFrame.Visible = true
	caughtFrame.BackgroundColor3 = Color3.new(1, 1, 1)
	caughtFrame.BackgroundTransparency = 0
	caughtText.TextTransparency = 1
	task.delay(0.08, function()
		caughtFrame.BackgroundColor3 = Color3.new(0, 0, 0)
		caughtText.TextTransparency = 0
	end)
	task.delay(2.4, function()
		local info = TweenInfo.new(1.2)
		TweenService:Create(caughtFrame, info, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(caughtText, info, { TextTransparency = 1 }):Play()
		task.delay(1.25, function()
			caughtFrame.Visible = false
		end)
	end)
end

-- Optional one-shot sound helper used by the controller and FX.
function CamcorderHud.playSound(soundId: string, volume: number)
	if soundId == "" then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume
	sound.Parent = gui
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	sound:Play()
end

return CamcorderHud
