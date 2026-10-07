--!strict
--[[
	DefenseShopController
	Path: StarterPlayerScripts.Client.Controllers.DefenseShopController

	ScreenGui "DefenseUI":
		* Defenses panel (B key / HUD button): barricades and sentries (placed) plus
		  accessories and utilities (instant), all priced in Match Coins
		* placement mode for placed defenses: a local ghost follows the cursor (or the
		  tapped point on touch), R / gamepad X rotates, click / tap / R2 confirms,
		  right-click / X key / gamepad B cancels. The weapon is holstered meanwhile so
		  confirming never also attacks.
		* local "Upgrade" prompts on every defense with a next level

	The ghost colour is only a hint; DefenseService re-validates the spot completely.

	API:
		DefenseShopController:BeginPlacement(defenseId)
		DefenseShopController:CancelPlacement()
		DefenseShopController:IsPlacing() -> boolean
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Attributes = require(Shared.Constants.Attributes)
local DefenseConfig = require(Shared.Config.DefenseConfig)
local Format = require(Shared.Utilities.Format)
local Janitor = require(Shared.Classes.Janitor)
local MathUtil = require(Shared.Utilities.MathUtil)

local Client = script:FindFirstAncestor("Client") :: Instance
local ClientState = require(Client.Modules.ClientState)
local Controllers = require(Client.Modules.ControllerRegistry)
local Net = require(Client.Modules.Net)
local Panels = require(Client.Modules.Panels)
local UIKit = require(Client.Modules.UIKit)

local player = Players.LocalPlayer
local Palette = UIKit.Palette

local DefenseShopController = {}

local ui: { [string]: any } = {}
local placement = Janitor.new()
local placing: string? = nil
local rotation = 0
local ghost: Part? = nil
local lastPoint: Vector3? = nil
local ownedAccessories: { [string]: boolean } = {}
local matchJanitor = Janitor.new()

local function sorted(map: { [string]: any }): { any }
	local list = {}
	for _, definition in map do
		table.insert(list, definition)
	end
	table.sort(list, function(a, b)
		return a.SortOrder < b.SortOrder
	end)
	return list
end

function DefenseShopController:Init()
	local screen = UIKit.Screen("DefenseUI", 10)
	ui.Screen = screen
	local frame = UIKit.Panel({
		Name = "Defenses",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.48),
		Size = UDim2.fromScale(0.6, 0.66),
		Parent = screen,
	})
	UIKit.Create("UISizeConstraint", { MinSize = Vector2.new(320, 320), MaxSize = Vector2.new(820, 560), Parent = frame })
	UIKit.Label({
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.new(1, -80, 0, 40),
		Text = "🧱 Defenses & Gear (Match Coins)",
		Font = UIKit.Fonts.Title,
		TextXAlignment = Enum.TextXAlignment.Left,
		MaxTextSize = 30,
		Parent = frame,
	})
	UIKit.Button({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 10),
		Size = UDim2.fromOffset(40, 40),
		Text = "✕",
		Color = Palette.Bad,
		OnClick = function()
			Panels.Close("DefenseUI")
		end,
		Parent = frame,
	})
	ui.List = UIKit.Create("ScrollingFrame", {
		Position = UDim2.fromOffset(12, 56),
		Size = UDim2.new(1, -24, 1, -68),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 8,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = frame,
	}, { UIKit.Grid(UDim2.fromOffset(230, 120), 10) })
	Panels.Register("DefenseUI", frame, function()
		DefenseShopController:Refresh()
	end)

	ui.Hint = UIKit.Label({
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -84),
		Size = UDim2.new(0.6, 0, 0, 28),
		Text = "",
		Visible = false,
		MaxTextSize = 20,
		Parent = screen,
	})
	ui.Cancel = UIKit.Button({
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -120),
		Size = UDim2.fromOffset(160, 44),
		Text = "Cancel",
		Color = Palette.Bad,
		Visible = false,
		OnClick = function()
			DefenseShopController:CancelPlacement()
		end,
		Parent = screen,
	})
end

local function card(order: number, title: string, body: string, buttonText: string, color: Color3, onClick: (() -> ())?)
	local panel = UIKit.Panel({ LayoutOrder = order, BackgroundColor3 = Palette.PanelLight, Parent = ui.List })
	UIKit.Label({
		Position = UDim2.fromOffset(8, 4),
		Size = UDim2.new(1, -16, 0, 26),
		Text = title,
		Font = UIKit.Fonts.Title,
		MaxTextSize = 20,
		Parent = panel,
	})
	UIKit.Label({
		Position = UDim2.fromOffset(8, 30),
		Size = UDim2.new(1, -16, 0, 40),
		Text = body,
		Font = UIKit.Fonts.Light,
		MaxTextSize = 14,
		Parent = panel,
	})
	UIKit.Button({
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -6),
		Size = UDim2.new(1, -16, 0, 38),
		Text = buttonText,
		Color = color,
		OnClick = onClick,
		Parent = panel,
	})
end

function DefenseShopController:Refresh()
	for _, child in ui.List:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local order = 0
	for _, definition in sorted(DefenseConfig.Defenses) do
		order += 1
		local stats = if definition.Kind == "Sentry"
			then `{definition.Damage} dmg • {definition.Range} range`
			else `{definition.MaxHealth} HP wall`
		card(order, `{definition.Icon} {definition.DisplayName}`, `{definition.Description}\n{stats}`, `🪙 {definition.Cost} • Place`, Palette.Info, function()
			self:BeginPlacement(definition.Id)
		end)
	end
	for _, item in sorted(DefenseConfig.Items) do
		order += 1
		local owned = item.Kind == "Accessory" and ownedAccessories[item.Id]
		card(order, `{item.Icon} {item.DisplayName}`, item.Description, if owned then "OWNED" else `🪙 {item.Cost}`, if owned then Palette.PanelStroke else Palette.Good, if owned
			then nil
			else function()
				task.spawn(function()
					local result = Net:Invoke("RequestPurchaseItem", item.Id)
					Controllers.NotificationController:ShowResult(result, `{item.DisplayName}!`)
					if result.Ok and item.Kind == "Accessory" then
						ownedAccessories[item.Id] = true
						self:Refresh()
					end
				end)
			end)
	end
end

-- Placement ------------------------------------------------------------------------------

-- Returns the camera ray under the pointer. Touch positions are GUI coordinates
-- (below the top-bar inset) and use ScreenPointToRay; the mouse location includes the
-- inset and pairs with ViewportPointToRay.
local function pointerRay(input: InputObject?): Ray
	local camera = Workspace.CurrentCamera
	if input and input.UserInputType == Enum.UserInputType.Touch then
		return camera:ScreenPointToRay(input.Position.X, input.Position.Y)
	end
	local mouse = UserInputService:GetMouseLocation()
	return camera:ViewportPointToRay(mouse.X, mouse.Y)
end

local function groundPointAt(ray: Ray): Vector3?
	local folder = ClientState.MatchFolder
	local map = folder and folder:FindFirstChild("Map")
	local ground = map and map:FindFirstChild("Ground")
	if ground == nil then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { ground }
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 300, params)
	return result and result.Position
end

local function looksValid(position: Vector3): boolean
	local folder = ClientState.MatchFolder
	if folder == nil then
		return false
	end
	local center = folder:FindFirstChild("GreatPumpkin")
	local centerPosition = if center and center:IsA("Model") then center:GetPivot().Position else position
	local distance = MathUtil.FlatDistance(position, centerPosition)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local near = root ~= nil and MathUtil.FlatDistance(root.Position, position) <= DefenseConfig.Placement.MaxPlaceDistance
	return near and distance >= DefenseConfig.Placement.InnerRadius and distance <= DefenseConfig.Placement.OuterRadius
end

local function updateGhost(input: InputObject?)
	local definition = placing and DefenseConfig.Defenses[placing]
	if definition == nil or ghost == nil then
		return
	end
	local point = groundPointAt(pointerRay(input))
	if point == nil then
		return
	end
	lastPoint = point
	ghost.CFrame = CFrame.new(point + Vector3.new(0, definition.Size.Y / 2, 0)) * CFrame.Angles(0, math.rad(rotation), 0)
	ghost.Color = if looksValid(point) then Palette.Good else Palette.Bad
end

local function confirm(input: InputObject?)
	local defenseId = placing
	if defenseId == nil then
		return
	end
	updateGhost(input)
	local point = lastPoint
	if point == nil then
		return
	end
	task.spawn(function()
		local result = Net:Invoke("RequestPurchaseDefense", defenseId, point, rotation)
		Controllers.NotificationController:ShowResult(result, "Built!")
		if result.Ok and not UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
			-- Hold Shift to keep placing the same defense.
			DefenseShopController:CancelPlacement()
		end
	end)
end

function DefenseShopController:IsPlacing(): boolean
	return placing ~= nil
end

function DefenseShopController:BeginPlacement(defenseId: string)
	local definition = DefenseConfig.Defenses[defenseId]
	if definition == nil or not ClientState.InMatch() then
		return
	end
	self:CancelPlacement()
	Panels.CloseAll()
	placing = defenseId
	Controllers.WeaponController:SetHolstered(true)

	local part = Instance.new("Part")
	part.Name = "PlacementGhost"
	part.Size = definition.Size
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 0.5
	part.Material = Enum.Material.ForceField
	part.Parent = Workspace.CurrentCamera
	ghost = placement:Add(part)

	ui.Hint.Text = if UIKit.IsTouch()
		then `Tap the ground to place {definition.DisplayName}`
		else `Click to place {definition.DisplayName} • R rotate • Shift keep placing • X / right-click cancel`
	ui.Hint.Visible = true
	ui.Cancel.Visible = true

	placement:Connect(RunService.RenderStepped, function()
		if not UIKit.IsTouch() then
			updateGhost(nil)
		end
	end)
	ContextActionService:BindActionAtPriority("PF_Place", function(_, state, input)
		if state == Enum.UserInputState.Begin then
			confirm(input)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.UserInputType.MouseButton1, Enum.UserInputType.Touch, Enum.KeyCode.ButtonR2)
	ContextActionService:BindActionAtPriority("PF_PlaceRotate", function(_, state)
		if state == Enum.UserInputState.Begin then
			rotation = (rotation + 90) % 360
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.R, Enum.KeyCode.ButtonX)
	ContextActionService:BindActionAtPriority("PF_PlaceCancel", function(_, state)
		if state == Enum.UserInputState.Begin then
			DefenseShopController:CancelPlacement()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.X, Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonB)
	placement:Add(function()
		ContextActionService:UnbindAction("PF_Place")
		ContextActionService:UnbindAction("PF_PlaceRotate")
		ContextActionService:UnbindAction("PF_PlaceCancel")
	end)
end

function DefenseShopController:CancelPlacement()
	if placing == nil then
		return
	end
	placing = nil
	ghost = nil
	lastPoint = nil
	placement:Cleanup()
	ui.Hint.Visible = false
	ui.Cancel.Visible = false
	Controllers.WeaponController:SetHolstered(false)
end

-- Upgrade prompts ------------------------------------------------------------------------

local function bindDefense(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local defenseId = model:GetAttribute(Attributes.DefenseId)
	local definition = defenseId and DefenseConfig.Defenses[defenseId]
	local base = model.PrimaryPart or model:WaitForChild("Base", 5)
	if definition == nil or base == nil or not base:IsA("BasePart") then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "UpgradePrompt"
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.HoldDuration = 0.5
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 12
	prompt.Parent = base
	local function update()
		local level = model:GetAttribute(Attributes.Level) or 0
		local upgrade = definition.Upgrades and definition.Upgrades[level + 1]
		local health = model:GetAttribute(Attributes.Health) or 0
		local maxHealth = model:GetAttribute(Attributes.MaxHealth) or 1
		prompt.ObjectText = `{definition.DisplayName} Lv{level} • {Format.Commas(health)}/{Format.Commas(maxHealth)}`
		prompt.ActionText = if upgrade then `Upgrade 🪙 {upgrade.Cost}` else "Max level"
		prompt.Enabled = upgrade ~= nil
	end
	model:GetAttributeChangedSignal(Attributes.Level):Connect(update)
	model:GetAttributeChangedSignal(Attributes.Health):Connect(update)
	update()
	prompt.Triggered:Connect(function()
		task.spawn(function()
			local result = Net:Invoke("RequestUpgradeDefense", model:GetAttribute(Attributes.DefenseUid))
			Controllers.NotificationController:ShowResult(result, "Upgraded!")
		end)
	end)
end

local function bindMatch(folder: Folder?)
	matchJanitor:Cleanup()
	table.clear(ownedAccessories)
	DefenseShopController:CancelPlacement()
	if folder == nil then
		Panels.Close("DefenseUI")
		return
	end
	local defenses = folder:WaitForChild("Defenses", 20)
	if defenses then
		matchJanitor:Connect(defenses.ChildAdded, function(child)
			task.spawn(bindDefense, child)
		end)
		for _, child in defenses:GetChildren() do
			task.spawn(bindDefense, child)
		end
	end
end

function DefenseShopController:Start()
	ClientState.MatchChanged:Connect(function(folder)
		task.spawn(bindMatch, folder)
	end)
	if ClientState.MatchFolder then
		task.spawn(bindMatch, ClientState.MatchFolder)
	end
	ContextActionService:BindAction("PF_ToggleDefenses", function(_, state)
		if state == Enum.UserInputState.Begin and ClientState.InMatch() then
			Panels.Toggle("DefenseUI")
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.B)
	ContextActionService:BindAction("PF_QuickHeal", function(_, state)
		if state == Enum.UserInputState.Begin and ClientState.InMatch() then
			Controllers.HUDController:UseHeal()
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.H)
end

return DefenseShopController
