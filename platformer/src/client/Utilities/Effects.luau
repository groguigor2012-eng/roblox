--!strict
-- Client-only visual effects. Nothing here replicates: every Instance is
-- created by this client inside Workspace.LocalEffects (or on the local
-- character) and is removed by a tween completion, Debris, or the
-- character's cleanup group.
--
-- Particle emitters for one-shot bursts are pooled: one host part per kind,
-- moved to the burst position before Emit(), so repeated effects never
-- clone particle systems. Uses only built-in rbxasset:// textures.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local CollectibleConfig = require(Config:WaitForChild("CollectibleConfig"))
local GameConfig = require(Config:WaitForChild("GameConfig"))
local MovementConfig = require(Config:WaitForChild("MovementConfig"))
local ResourceCleanup = require(Shared:WaitForChild("Utilities"):WaitForChild("ResourceCleanup"))
local Types = require(Shared:WaitForChild("Types"))

local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

export type CharacterRig = {
	JumpTrail: Trail,
	DashTrail: Trail,
	JumpEmitter: ParticleEmitter,
	DustEmitter: ParticleEmitter,
	TrailTokens: { [Trail]: number },
}

local Effects = {}

local effectsFolder: Folder? = nil
local emitterHosts: { [string]: { Part: Part, Emitter: ParticleEmitter } } = {}
local random = Random.new()

function Effects.GetFolder(): Folder
	local folder = effectsFolder
	if folder and folder.Parent == Workspace then
		return folder
	end
	local newFolder = Instance.new("Folder")
	newFolder.Name = GameConfig.Folders.LocalEffects
	newFolder.Parent = Workspace
	effectsFolder = newFolder
	return newFolder
end

local function newEffectPart(name: string, size: Vector3, cframe: CFrame): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = size
	part.CFrame = cframe
	return part
end

local function pooledEmitter(kind: string, configure: (ParticleEmitter) -> ()): (Part, ParticleEmitter)
	local host = emitterHosts[kind]
	if host and host.Part.Parent ~= nil then
		return host.Part, host.Emitter
	end
	local part = newEffectPart(`{kind}EmitterHost`, Vector3.one, CFrame.identity)
	local attachment = Instance.new("Attachment")
	attachment.Parent = part
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0
	emitter.Parent = attachment
	configure(emitter)
	part.Parent = Effects.GetFolder()
	emitterHosts[kind] = { Part = part, Emitter = emitter }
	return part, emitter
end

------------------------------------------------------------------------------
-- Per-character rig (created once per spawn, owned by the character cleanup)
------------------------------------------------------------------------------

function Effects.CreateCharacterRig(
	root: BasePart,
	feetOffset: number,
	cleanup: ResourceCleanup.ResourceCleanup
): CharacterRig
	local jumpConfig = MovementConfig.DoubleJump.Effects
	local dashConfig = MovementConfig.Dash.Effects
	local halfWidth = jumpConfig.TrailWidth / 2

	local top = cleanup:Add(Instance.new("Attachment"))
	top.Name = "PlatformerTrailTop"
	top.Position = Vector3.new(0, halfWidth, 0)
	top.Parent = root
	local bottom = cleanup:Add(Instance.new("Attachment"))
	bottom.Name = "PlatformerTrailBottom"
	bottom.Position = Vector3.new(0, -halfWidth, 0)
	bottom.Parent = root
	local feet = cleanup:Add(Instance.new("Attachment"))
	feet.Name = "PlatformerFeet"
	feet.Position = Vector3.new(0, -feetOffset + 0.2, 0)
	feet.Parent = root

	local function makeTrail(name: string, color: Color3, transparency: NumberSequence, lifetime: number): Trail
		local trail = cleanup:Add(Instance.new("Trail"))
		trail.Name = name
		trail.Attachment0 = top
		trail.Attachment1 = bottom
		trail.Color = ColorSequence.new(color)
		trail.Transparency = transparency
		trail.Lifetime = lifetime
		trail.LightEmission = 0.5
		trail.FaceCamera = true
		trail.Enabled = false
		trail.Parent = root
		return trail
	end

	local jumpEmitter = cleanup:Add(Instance.new("ParticleEmitter"))
	jumpEmitter.Name = "PlatformerJumpBurst"
	jumpEmitter.Rate = 0
	jumpEmitter.Texture = SPARKLE_TEXTURE
	jumpEmitter.Color = ColorSequence.new(jumpConfig.ParticleColor)
	jumpEmitter.Lifetime = jumpConfig.ParticleLifetime
	jumpEmitter.Size = jumpConfig.ParticleSize
	jumpEmitter.Speed = jumpConfig.ParticleSpeed
	jumpEmitter.Transparency = jumpConfig.ParticleTransparency
	jumpEmitter.SpreadAngle = Vector2.new(180, 20)
	jumpEmitter.EmissionDirection = Enum.NormalId.Bottom
	jumpEmitter.Drag = 4
	jumpEmitter.Parent = feet

	local dustEmitter = cleanup:Add(Instance.new("ParticleEmitter"))
	dustEmitter.Name = "PlatformerDust"
	dustEmitter.Rate = 0
	dustEmitter.Texture = SMOKE_TEXTURE
	dustEmitter.Color = ColorSequence.new(jumpConfig.ParticleColor)
	dustEmitter.Lifetime = NumberRange.new(0.3, 0.55)
	dustEmitter.Size = NumberSequence.new(1.2, 2.4)
	dustEmitter.Speed = NumberRange.new(4, 9)
	dustEmitter.Transparency = NumberSequence.new(0.35, 1)
	dustEmitter.SpreadAngle = Vector2.new(70, 10)
	dustEmitter.EmissionDirection = Enum.NormalId.Back
	dustEmitter.Drag = 5
	dustEmitter.Parent = feet

	return {
		JumpTrail = makeTrail("PlatformerJumpTrail", jumpConfig.TrailColor, jumpConfig.TrailTransparency, jumpConfig.TrailLifetime),
		DashTrail = makeTrail("PlatformerDashTrail", dashConfig.TrailColor, dashConfig.TrailTransparency, dashConfig.TrailLifetime),
		JumpEmitter = jumpEmitter,
		DustEmitter = dustEmitter,
		TrailTokens = {},
	}
end

-- Enables a trail for `duration` seconds. A newer pulse supersedes an older
-- one, so overlapping pulses never switch the trail off early.
function Effects.PulseTrail(rig: CharacterRig, trail: Trail, duration: number)
	local token = (rig.TrailTokens[trail] or 0) + 1
	rig.TrailTokens[trail] = token
	trail.Enabled = true
	task.delay(duration, function()
		if rig.TrailTokens[trail] == token and trail.Parent ~= nil then
			trail.Enabled = false
		end
	end)
end

function Effects.DoubleJumpBurst(rig: CharacterRig)
	Effects.PulseTrail(rig, rig.JumpTrail, MovementConfig.DoubleJump.Effects.TrailDuration)
	rig.JumpEmitter:Emit(MovementConfig.DoubleJump.Effects.BurstCount)
end

function Effects.DashBurst(rig: CharacterRig, duration: number)
	Effects.PulseTrail(rig, rig.DashTrail, duration)
	rig.DustEmitter:Emit(MovementConfig.Dash.Effects.DustCount)
end

------------------------------------------------------------------------------
-- Ground pound
------------------------------------------------------------------------------

local function expandingDisc(position: Vector3, radius: number, color: Color3, startTransparency: number, thickness: number, duration: number, heightOffset: number)
	local folder = Effects.GetFolder()
	-- Cylinders run along their X axis; rotate so the flat face points up.
	local cframe = CFrame.new(position + Vector3.new(0, thickness / 2 + heightOffset, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	local disc = newEffectPart("Shockwave", Vector3.new(thickness, 1, 1), cframe)
	disc.Shape = Enum.PartType.Cylinder
	disc.Material = Enum.Material.SmoothPlastic
	disc.Color = color
	disc.Transparency = startTransparency
	disc.Parent = folder

	local tween = TweenService:Create(
		disc,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(thickness, radius * 2, radius * 2), Transparency = 1 }
	)
	tween.Completed:Once(function()
		disc:Destroy()
	end)
	-- Safety net if the tween is interrupted (e.g. the folder is cleared).
	Debris:AddItem(disc, duration + 1)
	tween:Play()
end

-- Reusable radial shockwave: a dark ink disc with a paler rim that expands
-- slightly faster and wider, both fading to fully transparent.
function Effects.Shockwave(position: Vector3, radius: number)
	local shockwave = MovementConfig.GroundPound.Shockwave
	expandingDisc(position, radius, shockwave.Color, shockwave.StartTransparency, shockwave.Thickness, shockwave.Duration, 0.06)
	expandingDisc(
		position,
		radius * 1.08,
		shockwave.RimColor,
		shockwave.RimStartTransparency,
		shockwave.Thickness * 0.5,
		shockwave.Duration * 0.8,
		0.02
	)
end

function Effects.ImpactBurst(position: Vector3)
	local pound = MovementConfig.GroundPound
	local host, emitter = pooledEmitter("Impact", function(e)
		e.Texture = SMOKE_TEXTURE
		e.Color = ColorSequence.new(pound.ImpactParticleColor)
		e.Lifetime = NumberRange.new(0.35, 0.7)
		e.Size = NumberSequence.new(1.6, 3.2)
		e.Speed = NumberRange.new(14, 26)
		e.Transparency = NumberSequence.new(0.25, 1)
		e.SpreadAngle = Vector2.new(85, 85)
		e.EmissionDirection = Enum.NormalId.Top
		e.Acceleration = Vector3.new(0, -30, 0)
		e.Drag = 3
	end)
	host.CFrame = CFrame.new(position + Vector3.new(0, 0.3, 0))
	emitter:Emit(pound.ImpactParticleCount)
end

-- Local physics debris for parts the server broke. Chunks live in a
-- collision group that never collides with characters.
function Effects.DebrisChunks(broken: { Types.BrokenPartInfo })
	local pound = MovementConfig.GroundPound
	local folder = Effects.GetFolder()
	local budget = pound.MaxDebrisChunksPerImpact
	for _, info in broken do
		for _ = 1, pound.DebrisChunksPerPart do
			if budget <= 0 then
				return
			end
			budget -= 1
			local size = Vector3.new(
				math.clamp(info.Size.X / 3, 0.3, 2.5),
				math.clamp(info.Size.Y / 1.5, 0.3, 1.5),
				math.clamp(info.Size.Z / 3, 0.3, 2.5)
			) * random:NextNumber(0.6, 1)
			local offset = Vector3.new(
				random:NextNumber(-0.5, 0.5) * info.Size.X,
				0,
				random:NextNumber(-0.5, 0.5) * info.Size.Z
			)
			local chunk = Instance.new("Part")
			chunk.Name = "Debris"
			chunk.Size = size
			chunk.CFrame = info.CFrame * CFrame.new(offset)
			chunk.Color = info.Color
			chunk.Material = info.Material
			chunk.CanQuery = false
			chunk.CanTouch = false
			chunk.CastShadow = false
			chunk.CollisionGroup = GameConfig.CollisionGroups.VisualDebris
			chunk.Parent = folder
			chunk.AssemblyLinearVelocity = Vector3.new(random:NextNumber(-12, 12), random:NextNumber(10, 24), random:NextNumber(-12, 12))
			chunk.AssemblyAngularVelocity = Vector3.new(random:NextNumber(-8, 8), random:NextNumber(-8, 8), random:NextNumber(-8, 8))
			TweenService:Create(
				chunk,
				TweenInfo.new(pound.DebrisLifetime * 0.4, Enum.EasingStyle.Linear, Enum.EasingDirection.In, 0, false, pound.DebrisLifetime * 0.6),
				{ Transparency = 1 }
			):Play()
			Debris:AddItem(chunk, pound.DebrisLifetime)
		end
	end
end

------------------------------------------------------------------------------
-- Collectibles
------------------------------------------------------------------------------

function Effects.PickupBurst(position: Vector3, color: Color3)
	local host, emitter = pooledEmitter("Pickup", function(e)
		e.Texture = SPARKLE_TEXTURE
		e.Lifetime = NumberRange.new(0.3, 0.6)
		e.Size = NumberSequence.new(0.8, 0)
		e.Speed = NumberRange.new(6, 12)
		e.SpreadAngle = Vector2.new(180, 180)
		e.LightEmission = 1
		e.Drag = 4
	end)
	emitter.Color = ColorSequence.new(color)
	host.CFrame = CFrame.new(position)
	emitter:Emit(CollectibleConfig.Visual.SparkleCount)
end

-- Plays a grow-and-fade on a tag-free local copy, so the real instance can be
-- hidden immediately and keeps its original size and transparency.
function Effects.PickupGhost(instance: Instance)
	local ok, clone = pcall(function()
		return instance:Clone()
	end)
	if not ok or not clone then
		return -- Archivable = false or clone failed: skip the cosmetic
	end
	local visual = CollectibleConfig.Visual
	local info = TweenInfo.new(visual.PickupDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local parts: { BasePart } = {}
	for _, item in { clone, table.unpack(clone:GetDescendants()) } do
		for _, tag in item:GetTags() do
			item:RemoveTag(tag)
		end
		if item:IsA("BaseScript") then
			item:Destroy()
		elseif item:IsA("BasePart") then
			item.Anchored = true
			item.CanCollide = false
			item.CanQuery = false
			item.CanTouch = false
			item.LocalTransparencyModifier = 0
			table.insert(parts, item)
		end
	end
	clone.Parent = Effects.GetFolder()
	for _, part in parts do
		local goal: { [string]: any } = { Transparency = 1 }
		if part == clone then
			goal.Size = part.Size * visual.PickupScale
		end
		TweenService:Create(part, info, goal):Play()
	end
	Debris:AddItem(clone, visual.PickupDuration + 0.5)
end

function Effects.FloatingText(position: Vector3, text: string, color: Color3)
	local visual = CollectibleConfig.Visual
	local anchor = newEffectPart("FloatingText", Vector3.new(0.2, 0.2, 0.2), CFrame.new(position))
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(180, 40)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Adornee = anchor
	billboard.Parent = anchor
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeColor3 = Color3.fromRGB(12, 14, 20)
	label.TextStrokeTransparency = 0.3
	label.Parent = billboard
	anchor.Parent = Effects.GetFolder()

	local info = TweenInfo.new(visual.FloatingTextDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(anchor, info, { CFrame = anchor.CFrame + Vector3.new(0, visual.FloatingTextRise, 0) }):Play()
	TweenService:Create(label, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(anchor, visual.FloatingTextDuration + 0.25)
end

return Effects
