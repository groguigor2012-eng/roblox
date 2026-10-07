local roblox = require("@lune/roblox")
local Instance, Vector3, CFrame = roblox.Instance, roblox.Vector3, roblox.CFrame

-- Builds every procedural model and both maps through Lune's Instance emulation, which
-- rejects unknown properties and wrongly typed values exactly like the engine would.
return function(H)

	local ModelFactory = H.Module("Server.Systems.ModelFactory")
	local MapBuilder = H.Module("Server.Systems.MapBuilder")
	local CollisionGroups = H.Module("Server.Systems.CollisionGroups")
	local EnemyConfig = H.Module("Shared.Config.EnemyConfig")
	local CropConfig = H.Module("Shared.Config.CropConfig")
	local DefenseConfig = H.Module("Shared.Config.DefenseConfig")
	local WeaponConfig = H.Module("Shared.Config.WeaponConfig")
	local ClassConfig = H.Module("Shared.Config.ClassConfig")
	local MatchConfig = H.Module("Shared.Config.MatchConfig")
	local Attributes = H.Module("Shared.Constants.Attributes")
	local CollisionGroup = H.Module("Shared.Constants.CollisionGroup")

	for id, definition in EnemyConfig.Enemies do
		H.test(`enemy model {id}`, function()
			local model = ModelFactory.CreateEnemy(definition)
			H.ok(model.PrimaryPart and model.PrimaryPart.Name == "HumanoidRootPart", "root")
			H.ok(not model.PrimaryPart.Anchored, "root must be unanchored")
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if definition.MovementType == "Air" then
				H.eq(humanoid, nil, "flyers have no humanoid")
			else
				H.ok(humanoid, "walkers need a humanoid")
				H.eq(humanoid.RigType, roblox.Enum.HumanoidRigType.R15)
				H.ok(humanoid.HipHeight > 0)
				H.ok(not humanoid.RequiresNeck)
			end
			for _, part in model:GetDescendants() do
				if part:IsA("BasePart") and part ~= model.PrimaryPart then
					H.ok(part.Massless and not part.CanCollide and not part.Anchored, `{part.Name} must be a massless welded limb`)
				end
			end
			CollisionGroups.SetModel(model, CollisionGroup.Enemies)
			model:PivotTo(CFrame.new(10, 4, 10))
			H.ok(model:GetExtentsSize().Magnitude > 1)
		end)
	end

	for id, definition in CropConfig.Crops do
		H.test(`crop visuals {id}`, function()
			for _, stage in definition.Stages do
				local visual = ModelFactory.CreateCropVisual(definition, stage.Scale)
				H.eq(visual.Name, "Visual")
				H.ok(visual.PrimaryPart, "pivot")
				for _, part in visual:GetDescendants() do
					if part:IsA("BasePart") then
						H.ok(part.Anchored and not part.CanCollide, `{part.Name} must be anchored and non-colliding`)
					end
				end
			end
		end)
	end

	for id, definition in DefenseConfig.Defenses do
		H.test(`defense model {id}`, function()
			local model = ModelFactory.CreateDefense(definition)
			H.eq(model.PrimaryPart and model.PrimaryPart.Name, "Base")
			H.ok(model.PrimaryPart.CanCollide, "the base must block enemies")
			if definition.Kind == "Sentry" then
				H.ok(model:FindFirstChild("Head"), "sentries aim with a Head")
			end
		end)
	end

	for id, definition in WeaponConfig.Weapons do
		H.test(`weapon tool {id}`, function()
			local tool = ModelFactory.CreateWeaponTool(definition)
			H.ok(tool:IsA("Tool") and tool:FindFirstChild("Handle"))
			H.ok(not tool.CanBeDropped)
		end)
	end

	H.test("farm object models", function()
		local core = ModelFactory.CreateCore(MatchConfig.Core.Radius)
		H.ok(core.PrimaryPart)
		local chest = ModelFactory.CreateChest()
		H.ok(chest.PrimaryPart)
		local door = ModelFactory.CreateDoor()
		local portal = door:FindFirstChild("Portal")
		H.ok(portal and portal:FindFirstChild("EscapeAnchor") and portal:FindFirstChild("ContinueAnchor"))
	end)

	for id, definition in ClassConfig.Classes do
		H.test(`costume {id}`, function()
			local character = Instance.new("Model")
			local head = Instance.new("Part")
			head.Name = "Head"
			head.Parent = character
			ModelFactory.ApplyCostume(character, definition)
			ModelFactory.ApplyCostume(character, definition) -- re-applying replaces, never stacks
			local hats = 0
			for _, child in character:GetChildren() do
				if child.Name == "PF_CostumeHat" then
					hats += 1
				end
			end
			H.eq(hats, 1)
			H.eq(character:FindFirstChildOfClass("BodyColors").TorsoColor3, definition.Costume.PrimaryColor)
		end)
	end

	H.test("lighting configuration", function()
		MapBuilder.ConfigureLighting()
		local lighting = H.Service("Lighting")
		H.ok(lighting:FindFirstChildOfClass("Atmosphere"))
		MapBuilder.ConfigureLighting()
		local count = 0
		for _, child in lighting:GetChildren() do
			if child:IsA("BloomEffect") then
				count += 1
			end
		end
		H.eq(count, 1, "idempotent")
	end)

	H.test("lobby map", function()
		local workspaceFolder = Instance.new("Folder")
		local layout = MapBuilder.BuildLobby(workspaceFolder)
		H.ok(layout.PortalPrompt:IsA("ProximityPrompt"))
		local opensUi = {}
		for _, descendant in layout.Folder:GetDescendants() do
			if descendant:IsA("ProximityPrompt") and descendant:GetAttribute("OpensUI") then
				opensUi[descendant:GetAttribute("OpensUI")] = true
			end
		end
		H.ok(opensUi.ClassUI and opensUi.UpgradeUI, "wardrobe and upgrade prompts")
	end)

	H.test("arena map layout", function()
		local folder = Instance.new("Folder")
		local origin = Vector3.new(1200, 0, 0)
		local layout = MapBuilder.BuildArena(folder, origin)
		local farm = MatchConfig.Farm
		H.eq(#layout.PlotOrder, farm.PlotCount)
		local slots = 0
		local slotIds = {}
		for _, plot in layout.Plots do
			H.ok(plot.Part:GetAttribute(Attributes.Diggable))
			for _, slot in plot.Slots do
				slots += 1
				local key = `{plot.Id}:{slot.Index}`
				H.ok(not slotIds[key], "duplicate slot")
				slotIds[key] = true
				H.eq(slot.Part:GetAttribute(Attributes.PlotId), plot.Id)
				H.eq(slot.Part:GetAttribute(Attributes.SlotIndex), slot.Index)
				local flat = Vector3.new(slot.Position.X - origin.X, 0, slot.Position.Z - origin.Z).Magnitude
				H.ok(flat > MatchConfig.Core.FoundationRadius and flat < farm.FenceRadius, "slot inside the fence, outside the core")
			end
		end
		H.eq(slots, farm.PlotCount * farm.SlotColumns * farm.SlotRows)
		H.eq(#layout.Gates, farm.GateCount)
		H.eq(#layout.EnemySpawns, MatchConfig.Arena.EnemySpawnPoints)
		for _, spawn in layout.EnemySpawns do
			H.ok(spawn.X > layout.Bounds.MinX and spawn.X < layout.Bounds.MaxX and spawn.Z > layout.Bounds.MinZ and spawn.Z < layout.Bounds.MaxZ, "spawn inside bounds")
		end
		local diggable, noDig = 0, 0
		for _, part in layout.GroundFolder:GetChildren() do
			if part:GetAttribute(Attributes.Diggable) then
				diggable += 1
			end
			if part:GetAttribute(Attributes.NoDig) then
				noDig += 1
			end
		end
		H.ok(diggable >= 2 + farm.PlotCount, "floor, soil and plots are diggable")
		H.ok(noDig >= 2, "foundation and chest pad are protected")
		H.ok((layout.DoorCFrame.Position - origin).Magnitude < farm.FenceRadius, "door inside the farm")
	end)

	-- Runtime classes that build Instances --------------------------------------------------
	local Registry = H.Module("Server.Registry")
	local Crop = H.Module("Server.Classes.Crop")
	local Barricade = H.Module("Server.Classes.Barricade")
	local Sentry = H.Module("Server.Classes.Sentry")

	local function fakeMatchFolder()
		local folder = Instance.new("Folder")
		for _, name in { "Crops", "Defenses", "Enemies" } do
			local child = Instance.new("Folder")
			child.Name = name
			child.Parent = folder
		end
		return {
			Id = 1,
			Folder = folder,
			Sessions = {},
			Arena = { PropsFolder = Instance.new("Folder"), GroundFolder = Instance.new("Folder") },
		}
	end

	H.test("crop grows through every stage, regenerates and reflects thorns", function()
		local thornHits = 0
		Registry.DamageService = {
			DamageEnemy = function(_, _enemy, amount)
				thornHits += amount
				return amount
			end,
		}
		local match = fakeMatchFolder()
		local depleted = false
		local pepper = Crop.new(match, CropConfig.Crops.GhostPepper, { PlotId = "Plot1", Index = 2, Position = Vector3.new(5, 0.6, 5) }, nil, 1, function()
			depleted = true
		end)
		H.eq(pepper.Model.Parent, match.Folder.Crops)
		H.eq(pepper.Model:GetAttribute(Attributes.PlotId), "Plot1")
		H.ok(pepper.Model.PrimaryPart and pepper.Model.PrimaryPart.Name == "Anchor")
		local stages = {}
		for _ = 1, 200 do
			pepper:Update(1)
			stages[pepper.Model:GetAttribute(Attributes.Stage)] = true
		end
		H.ok(pepper:IsRipe() and pepper.Model:GetAttribute(Attributes.Ripe))
		H.ok(stages.Ripe and stages.Growing, "visited the growth stages")
		local attacker = { IsAlive = function() return true end }
		pepper:TakeDamage(20, { Enemy = attacker, MovementType = "Air" })
		H.eq(pepper.Health, pepper.MaxHealth - 20 * CropConfig.Crops.GhostPepper.Vulnerability.Air)
		H.eq(thornHits, CropConfig.Crops.GhostPepper.Special.Damage, "thorns hit back")
		pepper:TakeDamage(10_000, { Enemy = attacker })
		H.ok(depleted, "depleted callback fires at 0 health")

		local melon = Crop.new(match, CropConfig.Crops.WraithMelon, { PlotId = "Plot1", Index = 3, Position = Vector3.new(9, 0.6, 5) }, nil, 1, function() end)
		melon:TakeDamage(100, {})
		local hurt = melon.Health
		melon:Update(5)
		H.ok(melon.Health > hurt, "regenerates")
		H.ok(not CropConfig.Crops.VoidPumpkin.Special or Crop.new(match, CropConfig.Crops.VoidPumpkin, { PlotId = "Plot2", Index = 1, Position = Vector3.zero }, nil, 1, function() end):CanBeStolen() == false, "void pumpkins are anchored")
		melon:Destroy()
		H.eq(melon.Model.Parent, nil)
	end)

	H.test("barricade and sentry classes", function()
		local match = fakeMatchFolder()
		local destroyed = 0
		local wall = Barricade.new(match, DefenseConfig.Defenses.WoodenBarricade, CFrame.new(0, 0, 30), nil, function()
			destroyed += 1
		end)
		H.ok(wall.Model.PrimaryPart:FindFirstChildOfClass("PathfindingModifier"), "barricades carry the pathfinding cost modifier")
		H.eq(wall.Model.PrimaryPart.CollisionGroup, CollisionGroup.Defenses)
		wall:TakeDamage(100)
		local maxBefore = wall.MaxHealth
		wall:ApplyUpgrade()
		H.eq(wall.Level, 1)
		H.ok(wall.MaxHealth > maxBefore)
		H.eq(wall.MaxHealth - wall.Health, 100, "upgrade keeps the damage taken")
		wall:Repair(1)
		H.eq(wall.Health, wall.MaxHealth)
		wall:TakeDamage(1e6)
		H.eq(destroyed, 1)

		local turret = Sentry.new(match, DefenseConfig.Defenses.PumpkinSentry, CFrame.new(10, 0, 30), nil, function() end)
		local damage = turret:GetDamage()
		turret:ApplyUpgrade()
		H.ok(turret:GetDamage() > damage and turret:GetRange() > DefenseConfig.Defenses.PumpkinSentry.Range)
		H.eq(turret:GetNextUpgrade() ~= nil, #DefenseConfig.Defenses.PumpkinSentry.Upgrades > 1)
	end)
end
