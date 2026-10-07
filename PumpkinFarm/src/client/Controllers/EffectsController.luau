--!strict
--[[
	EffectsController
	Path: StarterPlayerScripts.Client.Controllers.EffectsController

	Renders every cosmetic event the server sends through the "Effect" remote, plus
	enemy health bars. Nothing here affects gameplay; it only visualises outcomes the
	server already decided. All parts live in a client-only folder
	(workspace.ClientEffects) and are removed with Debris, so nothing leaks.

	Projectiles are re-simulated locally from (Origin, Velocity, Gravity, MaxTime) using
	the same formula as the server's ProjectileSystem, so they line up with impacts.

	The EffectsEnabled profile setting reduces effects to the gameplay-critical ones
	(telegraphs, damage numbers, hurt flash).

	Asset hook: if ReplicatedStorage.Assets.Effects.<EffectName> (ParticleEmitter)
	exists, it is cloned and emitted at the effect position in addition to the
	procedural visual.

	API:
		EffectsController:Play(effectName, params)
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local CropConfig = require(Shared.Config.CropConfig)
local Janitor = require(Shared.Classes.Janitor)
local MathUtil = require(Shared.Utilities.MathUtil)

local Client = script:FindFirstAncestor("Client") :: Instance
local ClientState = require(Client.Modules.ClientState)
local Controllers = require(Client.Modules.ControllerRegistry)
local Net = require(Client.Modules.Net)
local UIKit = require(Client.Modules.UIKit)

local Palette = UIKit.Palette

local EffectsController = {}

local folder: Folder
local projectiles: { [number]: { Part: BasePart, Origin: Vector3, Velocity: Vector3, Gravity: number, Age: number, MaxTime: number } } = {}
local hurtFlash: Frame
local matchJanitor = Janitor.new()

local ESSENTIAL = {
	Leap = true,
	DamageNumber = true,
	Hurt = true,
	CoinPopup = true,
	Projectile = true,
}

local function effectsEnabled(): boolean
	local profile = ClientState.Profile
	return not (profile and profile.Settings and profile.Settings.EffectsEnabled == false)
end

local function part(props: { [string]: any }, lifetime: number): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = folder
	Debris:AddItem(p, lifetime)
	return p
end

local function tween(instance: Instance, goals: { [string]: any }, duration: number)
	TweenService:Create(instance, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goals):Play()
end

-- Expanding sphere that fades out.
local function burst(position: Vector3, radius: number, color: Color3, duration: number?)
	local d = duration or 0.35
	local p = part({ Shape = Enum.PartType.Ball, Size = Vector3.one, CFrame = CFrame.new(position), Color = color, Transparency = 0.3 }, d + 0.1)
	tween(p, { Size = Vector3.one * radius * 2, Transparency = 1 }, d)
end

-- Flat expanding ring on the ground.
local function ring(position: Vector3, radius: number, color: Color3, duration: number?)
	local d = duration or 0.45
	local p = part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 1, 1),
		CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90)),
		Color = color,
		Transparency = 0.25,
	}, d + 0.1)
	tween(p, { Size = Vector3.new(0.3, radius * 2, radius * 2), Transparency = 1 }, d)
end

local function floatingText(position: Vector3, text: string, color: Color3, size: number)
	local anchor = part({ Size = Vector3.one * 0.2, CFrame = CFrame.new(position + Vector3.new(0, 3, 0)), Transparency = 1 }, 1.2)
	local billboard = UIKit.Create("BillboardGui", {
		Size = UDim2.fromOffset(120, 40),
		AlwaysOnTop = true,
		Adornee = anchor,
		Parent = anchor,
	})
	local label = UIKit.Label({ Size = UDim2.fromScale(1, 1), Text = text, TextColor3 = color, Font = UIKit.Fonts.Title, MaxTextSize = size, Parent = billboard })
	tween(anchor, { CFrame = anchor.CFrame + Vector3.new(0, 3, 0) }, 1)
	tween(label, { TextTransparency = 1 }, 1.1)
end

local function emitAsset(effectName: string, position: Vector3)
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local effects = assets and assets:FindFirstChild("Effects")
	local template = effects and effects:FindFirstChild(effectName)
	if template and template:IsA("ParticleEmitter") then
		local holder = part({ Size = Vector3.one, CFrame = CFrame.new(position), Transparency = 1 }, 3)
		local emitter = template:Clone()
		emitter.Parent = holder
		emitter:Emit(20)
	end
end

local function dirt(position: Vector3, amount: number)
	for _ = 1, amount do
		local chunk = part({
			Size = Vector3.one * math.random(6, 12) / 10,
			CFrame = CFrame.new(position + Vector3.new(math.random(-15, 15) / 10, 0.5, math.random(-15, 15) / 10)),
			Color = Palette.Soil,
			Material = Enum.Material.Ground,
		}, 0.8)
		tween(chunk, { CFrame = chunk.CFrame + Vector3.new(math.random(-20, 20) / 10, math.random(20, 40) / 10, math.random(-20, 20) / 10), Transparency = 1 }, 0.7)
	end
end

local function cameraShake(intensity: number, duration: number)
	local camera = Workspace.CurrentCamera
	local started = os.clock()
	local connection
	connection = RunService.RenderStepped:Connect(function()
		local t = os.clock() - started
		if t > duration then
			connection:Disconnect()
			return
		end
		local strength = intensity * (1 - t / duration)
		camera.CFrame *= CFrame.Angles(math.rad((math.random() - 0.5) * strength), math.rad((math.random() - 0.5) * strength), 0)
	end)
end

local renderers: { [string]: (params: any) -> () } = {}

renderers.Projectile = function(params)
	local style = params.Style
	local color = params.Color or (if style == "Potion" then Color3.fromRGB(120, 255, 120) else Palette.AlienTeal)
	local bolt = part({
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * (if style == "Potion" then 1.4 else 1.1),
		CFrame = CFrame.new(params.Origin),
		Color = color,
		Material = if style == "Potion" then Enum.Material.Glass else Enum.Material.Neon,
	}, (params.MaxTime or 1) + 0.2)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 8
	light.Parent = bolt
	projectiles[params.Id] = {
		Part = bolt,
		Origin = params.Origin,
		Velocity = params.Velocity,
		Gravity = params.Gravity or 0,
		Age = 0,
		MaxTime = params.MaxTime or 1,
	}
end

renderers.Explosion = function(params)
	burst(params.Position, params.Radius or 6, params.Color or Palette.AlienTeal)
	Controllers.AudioController:Play("Explosion")
end

renderers.HexNova = function(params)
	ring(params.Position, params.Radius or 12, Palette.AlienPurple, 0.6)
	burst(params.Position, (params.Radius or 12) * 0.6, Palette.AlienPurple, 0.5)
	Controllers.AudioController:Play("Explosion")
end

renderers.Slash = function(params)
	local position: Vector3 = params.Position
	local direction: Vector3 = params.Direction or Vector3.new(0, 0, -1)
	local radius = params.Radius or 8
	local arc = part({
		Size = Vector3.new(radius * 1.6, 0.3, radius),
		CFrame = CFrame.lookAt(position, position + direction) * CFrame.new(0, 0, -radius / 2),
		Color = params.Color or Palette.Accent,
		Transparency = 0.35,
	}, 0.3)
	tween(arc, { Transparency = 1 }, 0.25)
end

renderers.Whirl = function(params)
	ring(params.Position, params.Radius or 12, Palette.Accent, 0.4)
end

renderers.PotionSplash = function(params)
	burst(params.Position, params.Radius or 8, Color3.fromRGB(110, 255, 110), 0.5)
end

renderers.DigIn = function(params)
	dirt(params.Position, 10)
end

renderers.DigOut = function(params)
	dirt(params.Position, 14)
	ring(params.Position, 5, Palette.Soil, 0.4)
end

renderers.Leap = function(params)
	-- Telegraph the landing zone for the whole wind-up + flight so players can dodge.
	local duration = params.Duration or 1.2
	local marker = part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, (params.Radius or 9) * 2, (params.Radius or 9) * 2),
		CFrame = CFrame.new(params.Position + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Palette.Bad,
		Transparency = 0.55,
	}, duration + 0.1)
	tween(marker, { Transparency = 0.2 }, duration)
end

renderers.Shockwave = function(params)
	ring(params.Position, params.Radius or 9, Palette.Warning, 0.4)
	cameraShake(1.5, 0.25)
end

renderers.Stun = function(params)
	ring(params.Position + Vector3.new(0, 4, 0), 2.5, Palette.Warning, params.Duration or 2)
end

renderers.DamageNumber = function(params)
	floatingText(params.Position, tostring(params.Amount or 0), Palette.Warning, 26)
end

renderers.CoinPopup = function(params)
	floatingText(params.Position + Vector3.new(0, 1.5, 0), `+{params.Amount or 0} 🪙`, Palette.Coin, 22)
end

renderers.Hurt = function(_params)
	hurtFlash.BackgroundTransparency = 0.6
	tween(hurtFlash, { BackgroundTransparency = 1 }, 0.35)
	Controllers.AudioController:Play("Hurt")
end

renderers.Plant = function(params)
	ring(params.Position, 2.5, Palette.Good, 0.35)
end

renderers.Harvest = function(params)
	local definition = params.CropId and CropConfig.Get(params.CropId)
	burst(params.Position + Vector3.new(0, 2, 0), 3, definition and definition.Visual.Color or Palette.Coin, 0.4)
end

renderers.CropDestroyed = function(params)
	dirt(params.Position, 8)
end

renderers.Steal = function(params)
	burst(params.Position, 3, Palette.AlienPurple, 0.4)
end

renderers.Summon = function(params)
	ring(params.Position, 7, Color3.fromRGB(120, 255, 140), 0.6)
end

renderers.BossSweep = function(params)
	ring(params.Position, params.Radius or 16, Palette.Boss, 0.5)
	cameraShake(2, 0.3)
end

renderers.BossCrush = function(params)
	dirt(params.Position, 12)
	cameraShake(2.5, 0.3)
end

renderers.SentryBolt = function(params)
	local from: Vector3, to: Vector3 = params.From, params.To
	local length = (to - from).Magnitude
	local beam = part({
		Size = Vector3.new(0.25, 0.25, length),
		CFrame = CFrame.lookAt(from, to) * CFrame.new(0, 0, -length / 2),
		Color = params.Color or Palette.PumpkinOrange,
	}, 0.12)
	tween(beam, { Transparency = 1 }, 0.1)
end

renderers.LanternPulse = function(params)
	ring(params.Position, params.Radius or 20, Palette.Info, 0.6)
end

renderers.Heal = function(params)
	burst(params.Position, 4, Palette.Good, 0.4)
end

renderers.Repair = function(params)
	burst(params.Position + Vector3.new(0, 2, 0), 3, Palette.Coin, 0.3)
end

renderers.Build = function(params)
	ring(params.Position, 6, Palette.Wood, 0.4)
end

renderers.DefenseDestroyed = function(params)
	burst(params.Position + Vector3.new(0, 2, 0), 5, Palette.Wood, 0.4)
end

renderers.Death = function(params)
	burst(params.Position, if params.IsBoss then 20 else 3, if params.IsBoss then Palette.Boss else Palette.AlienPurple, if params.IsBoss then 1 else 0.35)
end

function EffectsController:Play(effectName: string, params: any)
	if type(params) ~= "table" then
		return
	end
	if not effectsEnabled() and not ESSENTIAL[effectName] then
		return
	end
	local renderer = renderers[effectName]
	if renderer then
		local ok, err = pcall(renderer, params)
		if not ok then
			warn(`[EffectsController] {effectName} failed: {err}`)
		end
	end
	if params.Position then
		emitAsset(effectName, params.Position)
	end
end

-- Enemy health bars -------------------------------------------------------------------

local function bindEnemy(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local root = model:WaitForChild("HumanoidRootPart", 5)
	if root == nil or model:GetAttribute(Attributes.EnemyId) == "CursedHarvester" then
		return
	end
	local extents = model:GetExtentsSize()
	local billboard = UIKit.Create("BillboardGui", {
		Name = "HealthBar",
		Size = UDim2.fromOffset(70, 10),
		StudsOffset = Vector3.new(0, extents.Y / 2 + 1, 0),
		MaxDistance = 90,
		Adornee = root,
		Enabled = false,
		Parent = model,
	})
	local bar = UIKit.Bar({ Size = UDim2.fromScale(1, 1), Color = Palette.Bad, MaxTextSize = 1, Parent = billboard })
	local function update()
		local health = model:GetAttribute(Attributes.Health) or 0
		local maxHealth = model:GetAttribute(Attributes.MaxHealth) or 1
		billboard.Enabled = health > 0 and health < maxHealth
		bar:Set(health / math.max(1, maxHealth))
	end
	model:GetAttributeChangedSignal(Attributes.Health):Connect(update)
	update()
end

local function bindMatch(match: Folder?)
	matchJanitor:Cleanup()
	if match == nil then
		return
	end
	local enemies = match:WaitForChild("Enemies", 20)
	if enemies then
		matchJanitor:Connect(enemies.ChildAdded, function(child)
			task.spawn(bindEnemy, child)
		end)
		for _, child in enemies:GetChildren() do
			task.spawn(bindEnemy, child)
		end
	end
end

function EffectsController:Init()
	folder = Instance.new("Folder")
	folder.Name = "ClientEffects"
	folder.Parent = Workspace

	local screen = UIKit.Screen("EffectsUI", 0)
	hurtFlash = UIKit.Create("Frame", {
		Name = "HurtFlash",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Palette.Bad,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = screen,
	})
end

function EffectsController:Start()
	Net:On("Effect", function(effectName: string, params: any)
		self:Play(effectName, params)
	end)
	RunService.Heartbeat:Connect(function(dt)
		for id, projectile in projectiles do
			projectile.Age += dt
			if projectile.Age >= projectile.MaxTime or projectile.Part.Parent == nil then
				projectile.Part:Destroy()
				projectiles[id] = nil
			else
				projectile.Part.CFrame = CFrame.new(MathUtil.SampleBallistic(projectile.Origin, projectile.Velocity, projectile.Gravity, projectile.Age))
			end
		end
	end)
	ClientState.MatchChanged:Connect(function(match)
		task.spawn(bindMatch, match)
	end)
	if ClientState.MatchFolder then
		task.spawn(bindMatch, ClientState.MatchFolder)
	end
end

return EffectsController
