--!strict
--[[
	WeaponController
	Path: StarterPlayerScripts.Client.Controllers.WeaponController

	Turns player input into attack INTENT:
		attack   Tool.Activated (mouse click, touch tap, gamepad R2)
		ability  Q / gamepad Y / on-screen button
	Each request carries only an aim point and (for attacks) a strictly increasing
	sequence number. The server decides hits, damage and cooldowns; the local cooldown
	here only prevents pointless requests and drives the ability button display.

	Aim: mouse/cursor ray on desktop; on touch, the nearest enemy roughly in front of
	the camera within 60 studs, otherwise a point ahead of the character.

	API:
		WeaponController:SetHolstered(holstered)   -- used by placement mode
		WeaponController:GetAimPoint() -> Vector3?
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local Client = script:FindFirstAncestor("Client") :: Instance
local ClientState = require(Client.Modules.ClientState)
local Controllers = require(Client.Modules.ControllerRegistry)
local Net = require(Client.Modules.Net)
local UIKit = require(Client.Modules.UIKit)

local player = Players.LocalPlayer
local Palette = UIKit.Palette

local WeaponController = {}

local sequence = 0
local readyAt = 0
local abilityReadyAt = 0
local currentTool: Tool? = nil
local toolConnection: RBXScriptConnection? = nil
local holstered = false
local abilityButton: TextButton

local function stunned(): boolean
	local raw = player:GetAttribute(Attributes.Effects)
	return type(raw) == "string" and raw:find("Stunned", 1, true) ~= nil
end

local function aimParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { Workspace.CurrentCamera }
	if player.Character then
		table.insert(exclude, player.Character)
	end
	params.FilterDescendantsInstances = exclude
	return params
end

function WeaponController:GetAimPoint(): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root == nil then
		return nil
	end
	local camera = Workspace.CurrentCamera
	if UIKit.IsTouch() then
		local folder = ClientState.MatchFolder
		local enemies = folder and folder:FindFirstChild("Enemies")
		local best, bestScore = nil, math.huge
		if enemies then
			local forward = camera.CFrame.LookVector
			for _, model in enemies:GetChildren() do
				if model:IsA("Model") and (model:GetAttribute(Attributes.Health) or 0) > 0 then
					local offset = model:GetPivot().Position - root.Position
					local distance = offset.Magnitude
					if distance < 60 and distance > 0.1 and forward:Dot(offset.Unit) > 0.3 and distance < bestScore then
						best, bestScore = model:GetPivot().Position, distance
					end
				end
			end
		end
		return best or (root.Position + root.CFrame.LookVector * 30)
	end
	local mouse = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 300, aimParams())
	return if result then result.Position else ray.Origin + ray.Direction * 150
end

local function weaponDefinition(): any
	local tool = currentTool
	local weaponId = tool and tool:GetAttribute(Attributes.WeaponId)
	return weaponId and WeaponConfig.Weapons[weaponId]
end

local function attack()
	if holstered or stunned() then
		return
	end
	local definition = weaponDefinition()
	local now = os.clock()
	if definition == nil or now < readyAt then
		return
	end
	local aim = WeaponController:GetAimPoint()
	if aim == nil then
		return
	end
	readyAt = now + definition.Cooldown
	sequence += 1
	Net:Fire("RequestAttack", aim, sequence)
	Controllers.AudioController:Play(if definition.Visual.Kind == "Staff" then "CastBolt" else "Slash")
end

local function useAbility()
	local tool = currentTool
	local abilityId = tool and tool:GetAttribute("AbilityId")
	local ability = abilityId and WeaponConfig.Abilities[abilityId]
	local now = os.clock()
	if ability == nil or holstered or stunned() or now < abilityReadyAt then
		return
	end
	local aim = WeaponController:GetAimPoint()
	if aim == nil then
		return
	end
	abilityReadyAt = now + ability.Cooldown
	Net:Fire("RequestUseAbility", ability.Id, aim)
	Controllers.AudioController:Play("Whirl")
end

local function bindTool(tool: Tool)
	if tool:GetAttribute(Attributes.WeaponId) == nil then
		return
	end
	currentTool = tool
	if toolConnection then
		toolConnection:Disconnect()
	end
	toolConnection = tool.Activated:Connect(attack)
end

local function bindCharacter(character: Model)
	currentTool = nil
	readyAt = 0
	character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			bindTool(child)
		end
	end)
	for _, child in character:GetChildren() do
		if child:IsA("Tool") then
			bindTool(child)
		end
	end
end

function WeaponController:SetHolstered(value: boolean)
	holstered = value
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end
	if value then
		humanoid:UnequipTools()
	elseif currentTool and currentTool.Parent ~= nil and currentTool.Parent ~= character then
		humanoid:EquipTool(currentTool)
	end
end

function WeaponController:Init()
	local screen = UIKit.Screen("CombatUI", 3)
	abilityButton = UIKit.Button({
		Name = "Ability",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -16),
		Size = UDim2.fromOffset(120, 64),
		Text = "Ability [Q]",
		Color = Palette.AlienPurple,
		Visible = false,
		OnClick = useAbility,
		Parent = screen,
	})
end

function WeaponController:Start()
	if player.Character then
		bindCharacter(player.Character)
	end
	player.CharacterAdded:Connect(bindCharacter)

	ContextActionService:BindAction("PF_Ability", function(_, state)
		if state == Enum.UserInputState.Begin then
			useAbility()
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.Q, Enum.KeyCode.ButtonY)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 0.1 then
			return
		end
		accumulator = 0
		local tool = currentTool
		local abilityId = tool and tool:GetAttribute("AbilityId")
		local ability = abilityId and WeaponConfig.Abilities[abilityId]
		abilityButton.Visible = ability ~= nil and ClientState.InMatch() and tool ~= nil and tool.Parent ~= nil
		if ability then
			local remaining = abilityReadyAt - os.clock()
			abilityButton.Text = if remaining > 0
				then `{ability.DisplayName}\n{math.ceil(remaining)}s`
				else `{ability.DisplayName}\n[Q]`
		end
	end)
end

return WeaponController
