--!strict
-- Local damage feedback: a red screen flash and a short camera shake when
-- the local Humanoid loses health. Healing never triggers feedback.
--
-- One overlay and at most one render-step binding exist at any time:
--   * a new flash cancels the running flash tween and restarts from the new
--     intensity, so overlays never stack or stay visible
--   * shake is a "trauma" value in [0, 1]; hits add trauma (capped at 1),
--     it decays linearly, and the binding is removed as soon as it reaches 0
-- The shake is translation-only in camera space, applied after Roblox's
-- camera update, so it never accumulates, never changes CameraType and never
-- rotates the camera's look direction.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local HealthUIConfig = require(Shared:WaitForChild("Config"):WaitForChild("HealthUIConfig"))

local Client = script.Parent.Parent
local CharacterLifecycle = require(Client.Utilities.CharacterLifecycle)

local Feedback = HealthUIConfig.DamageFeedback
local SHAKE_BINDING = "PlatformerCameraShake"

local FeedbackController = {}

local overlay: Frame? = nil
local flashTween: Tween? = nil
local trauma = 0
local shakeBound = false
local started = false

local function unbindShake()
	if shakeBound then
		RunService:UnbindFromRenderStep(SHAKE_BINDING)
		shakeBound = false
	end
	trauma = 0
end

local function shakeStep(deltaTime: number)
	trauma = math.max(0, trauma - Feedback.TraumaDecayPerSecond * deltaTime)
	if trauma <= 0 then
		unbindShake()
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local strength = Feedback.ShakeMaxOffset * trauma * trauma
	local t = os.clock() * Feedback.ShakeFrequency
	local offset = Vector3.new(math.noise(t, 0.5) * strength, math.noise(0.5, t) * strength, 0)
	camera.CFrame *= CFrame.new(offset)
end

-- Adds camera-shake trauma (clamped to [0, 1]).
function FeedbackController.AddTrauma(amount: number)
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return
	end
	trauma = math.min(1, trauma + amount)
	if not shakeBound then
		shakeBound = true
		RunService:BindToRenderStep(SHAKE_BINDING, Enum.RenderPriority.Camera.Value + 1, shakeStep)
	end
end

-- Flashes the red overlay at `intensity` in [0, 1].
function FeedbackController.Flash(intensity: number)
	local frame = overlay
	if not frame then
		return
	end
	if flashTween then
		flashTween:Cancel()
	end
	local clamped = math.clamp(intensity, 0, 1)
	frame.BackgroundTransparency = 1 - Feedback.FlashMaxOpacity * clamped
	local tween = TweenService:Create(
		frame,
		TweenInfo.new(Feedback.FlashDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	flashTween = tween
	tween:Play()
end

local function onDamage(amount: number, maxHealth: number)
	local fraction = if maxHealth > 0 then math.clamp(amount / maxHealth, 0, 1) else 1
	FeedbackController.Flash(Feedback.FlashBaseIntensity + fraction * Feedback.FlashIntensityPerHealthFraction)
	FeedbackController.AddTrauma(Feedback.ShakeBaseTrauma + fraction * Feedback.ShakeTraumaPerHealthFraction)
end

local function onSpawn(context: CharacterLifecycle.Context)
	local humanoid = context.Humanoid
	local previousHealth = humanoid.Health
	unbindShake()
	context.Cleanup:Connect(humanoid.HealthChanged, function(health: number)
		local delta = health - previousHealth
		previousHealth = health
		-- A drop that lands exactly on MaxHealth is a MaxHealth change, not damage.
		if -delta >= Feedback.MinDamage and health < humanoid.MaxHealth then
			onDamage(-delta, humanoid.MaxHealth)
		end
	end)
end

local function buildOverlay(): Frame
	local gui = Instance.new("ScreenGui")
	gui.Name = "PlatformerDamageFlash"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = Feedback.FlashDisplayOrder
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local frame = Instance.new("Frame")
	frame.Name = "Flash"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Feedback.FlashColor
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Active = false
	frame.Parent = gui

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return frame
end

function FeedbackController.Start()
	assert(not started, "FeedbackController already started")
	started = true
	overlay = buildOverlay()
	CharacterLifecycle.Register("FeedbackController", {
		OnSpawn = onSpawn,
		OnDespawn = function()
			unbindShake()
		end,
	})
end

return FeedbackController
