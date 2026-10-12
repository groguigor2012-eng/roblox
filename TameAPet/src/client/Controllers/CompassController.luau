-- The compass HUD widget. The server picks the target egg (CompassTarget) at a fixed
-- interval; this controller only turns the target's world position into a needle angle
-- relative to where the player is looking, eases the needle, shows the distance and makes the
-- dial glow brighter as the player gets closer. It never needs the egg model to be streamed in.
-- The per-frame update runs only while a compass is equipped.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = ReplicatedStorage:WaitForChild("Config")
local CompassConfig = require(Config:WaitForChild("CompassConfig"))
local EggConfig = require(Config:WaitForChild("EggConfig"))
local RarityConfig = require(Config:WaitForChild("RarityConfig"))
local Format = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Format"))
local UIKit = require(script.Parent.Parent.UIControllers.UIKit)

local Theme = UIKit.Theme
local Tracking = CompassConfig.Tracking
local player = Players.LocalPlayer

local CompassController = {}

local controllers
local ClientState

local widget: Frame
local glow: Frame
local dialStroke: UIStroke
local needleHolder: Frame
local distanceLabel: TextLabel
local targetLabel: TextLabel
local renderConnection: RBXScriptConnection?
local needleAngle = 0

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Signed angle (degrees, clockwise positive) from the camera's flat look direction to the target.
function CompassController.bearing(cameraLook: Vector3, from: Vector3, to: Vector3): number?
	local flatLook = Vector3.new(cameraLook.X, 0, cameraLook.Z)
	local offset = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if flatLook.Magnitude < 1e-3 or offset.Magnitude < 1e-3 then
		return nil
	end
	flatLook = flatLook.Unit
	local right = Vector3.new(-flatLook.Z, 0, flatLook.X)
	return math.deg(math.atan2(offset:Dot(right), offset:Dot(flatLook)))
end

local function setGlow(distance: number?)
	local alpha = 0
	if distance then
		alpha = 1 - math.clamp(distance / Tracking.MaxGlowDistance, 0, 1)
	end
	glow.BackgroundTransparency = lerp(Tracking.GlowTransparencyFar, Tracking.GlowTransparencyNear, alpha)
	dialStroke.Thickness = lerp(Tracking.StrokeThicknessFar, Tracking.StrokeThicknessNear, alpha)
end

local function step(dt: number)
	local target = ClientState.compassTarget
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local camera = workspace.CurrentCamera

	local desired: number? = nil
	local distance: number? = nil
	if target and not target.none and typeof(target.position) == "Vector3" and root and root:IsA("BasePart") then
		desired = CompassController.bearing(camera.CFrame.LookVector, root.Position, target.position)
		distance = (target.position - root.Position).Magnitude
	end

	if desired and distance then
		local delta = ((desired - needleAngle + 180) % 360) - 180
		needleAngle += delta * math.min(1, dt * Tracking.NeedleLerpSpeed)
		if distance <= Tracking.ArrivedDistance then
			distanceLabel.Text = "Right here!"
		else
			distanceLabel.Text = Format.distance(distance, Tracking.DistanceDecimalsOver, Tracking.DistanceUnit)
		end
		distanceLabel.TextColor3 = Theme.Text
	else
		needleAngle += Tracking.NoTargetSpinSpeed * dt
		distanceLabel.Text = Tracking.NoTargetText
		distanceLabel.TextColor3 = Theme.TextDim
	end
	needleAngle %= 360
	needleHolder.Rotation = needleAngle
	setGlow(distance)
end

local function refreshTargetLabel()
	local target = ClientState.compassTarget
	if target and not target.none then
		local tier = EggConfig.Tiers[target.tier]
		targetLabel.Text = if tier then tier.displayName else "Egg"
		targetLabel.TextColor3 = RarityConfig.color(target.tier)
	else
		targetLabel.Text = "Searching..."
		targetLabel.TextColor3 = Theme.TextDim
	end
end

local function refreshVisibility()
	local profile = ClientState.profile
	local compass = profile and CompassConfig.Compasses[profile.equippedCompass]
	widget.Visible = compass ~= nil
	if compass then
		glow.BackgroundColor3 = compass.color
		dialStroke.Color = compass.color
		if not renderConnection then
			renderConnection = RunService.RenderStepped:Connect(step)
		end
	elseif renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
end

function CompassController.init(c)
	controllers = c
	ClientState = c.ClientState
end

function CompassController.start()
	local gui = controllers.HudController.gui
	widget = UIKit.new("Frame", {
		Name = "Compass",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -16),
		Size = UDim2.fromOffset(170, 210),
		Visible = false,
		Parent = gui,
	})
	glow = UIKit.new("Frame", {
		Name = "Glow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(85, 80),
		Size = UDim2.fromOffset(160, 160),
		BackgroundColor3 = Theme.Accent,
		BackgroundTransparency = Tracking.GlowTransparencyFar,
		Parent = widget,
	}, { UIKit.corner(80) })
	local dial = UIKit.new("Frame", {
		Name = "Dial",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(85, 80),
		Size = UDim2.fromOffset(128, 128),
		BackgroundColor3 = Theme.Background,
		BackgroundTransparency = 0.05,
		Parent = widget,
	}, { UIKit.corner(64) })
	dialStroke = UIKit.stroke(Theme.Accent, Tracking.StrokeThicknessFar, 0)
	dialStroke.Parent = dial

	-- "Ahead" marker at the top of the dial: the needle points relative to the view.
	UIKit.label({
		Text = "▲",
		TextSize = 14,
		TextColor3 = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 4),
		Size = UDim2.fromOffset(20, 16),
		Parent = dial,
	})

	needleHolder = UIKit.new("Frame", {
		Name = "Needle",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Parent = dial,
	})
	UIKit.new("Frame", {
		Name = "Tip",
		BackgroundColor3 = Theme.Danger,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(8, 48),
		Parent = needleHolder,
	}, { UIKit.corner(4) })
	UIKit.new("Frame", {
		Name = "Tail",
		BackgroundColor3 = Theme.TextDim,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(6, 30),
		Parent = needleHolder,
	}, { UIKit.corner(3) })
	UIKit.new("Frame", {
		Name = "Hub",
		BackgroundColor3 = Theme.Text,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(14, 14),
		ZIndex = 3,
		Parent = dial,
	}, { UIKit.corner(7) })

	targetLabel = UIKit.label({
		Text = "Searching...",
		Font = Theme.FontBlack,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.4,
		Position = UDim2.fromOffset(0, 160),
		Size = UDim2.new(1, 0, 0, 20),
		Parent = widget,
	})
	distanceLabel = UIKit.label({
		Text = "",
		Font = Theme.FontBold,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.4,
		Position = UDim2.fromOffset(0, 182),
		Size = UDim2.new(1, 0, 0, 22),
		Parent = widget,
	})

	ClientState.ProfileChanged:Connect(refreshVisibility)
	ClientState.CompassTargetChanged:Connect(refreshTargetLabel)
	refreshVisibility()
	refreshTargetLabel()
end

return CompassController
