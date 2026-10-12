-- Main HUD: currency, live speed, equipped pet/compass, menu buttons, ride button and context
-- hints. Event-driven from ClientState except the speed readout (sampled at 10 Hz).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = ReplicatedStorage:WaitForChild("Config")
local GameConfig = require(Config:WaitForChild("GameConfig"))
local UIConfig = require(Config:WaitForChild("UIConfig"))
local CompassConfig = require(Config:WaitForChild("CompassConfig"))
local RarityConfig = require(Config:WaitForChild("RarityConfig"))
local Format = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Format"))
local UIKit = require(script.Parent.UIKit)

local Theme = UIKit.Theme
local player = Players.LocalPlayer

local HudController = {}
HudController.gui = nil :: ScreenGui?

local controllers
local ClientState

local currencyLabel: TextLabel
local speedLabel: TextLabel
local petLabel: TextLabel
local compassLabel: TextLabel
local hintLabel: TextLabel
local rideButton: UIKit.Button
local displayedCurrency = 0

local function statRow(parent: Instance, icon: string, order: number, accent: Color3): TextLabel
	local row = UIKit.new("Frame", {
		BackgroundColor3 = Theme.Background,
		BackgroundTransparency = 0.25,
		Size = UDim2.fromOffset(250, 40),
		LayoutOrder = order,
		Parent = parent,
	}, { UIKit.corner(10), UIKit.stroke(accent, 1.5, 0.4) })
	UIKit.label({
		Text = icon,
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromOffset(40, 40),
		Parent = row,
	})
	return UIKit.label({
		Text = "...",
		Font = Theme.FontBold,
		TextSize = 17,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Position = UDim2.fromOffset(40, 0),
		Size = UDim2.new(1, -48, 1, 0),
		Parent = row,
	})
end

local function keyName(keyCode: Enum.KeyCode): string
	return UserInputService:GetStringForKeyCode(keyCode) ~= "" and UserInputService:GetStringForKeyCode(keyCode)
		or keyCode.Name
end

local function refreshHint()
	local profile = ClientState.profile
	local mount = ClientState.mount
	local keys = UIConfig.Keybinds
	local touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	if not profile then
		hintLabel.Text = "Loading your profile..."
	elseif mount.mounted then
		if touch then
			hintLabel.Text = if mount.canFly
				then "Thumbstick to steer · Up/Down buttons to fly · Dismount button to hop off"
				else "Thumbstick to steer · Jump button to jump · Dismount button to hop off"
		else
			hintLabel.Text = if mount.canFly
				then `WASD steer · {keyName(keys.Ascend)} climb · {keyName(keys.Descend)}/{keyName(keys.DescendAlt)} descend & land · {keyName(keys.ToggleMount)} dismount`
				else `WASD steer · {keyName(keys.Ascend)} jump · {keyName(keys.ToggleMount)} dismount`
		end
	elseif #profile.compasses == 0 then
		hintLabel.Text = `Visit the Compass Merchant or press {keyName(keys.Shop)} to buy a compass`
	elseif profile.equippedCompass == "" then
		hintLabel.Text = `Equip a compass from your inventory ({keyName(keys.Inventory)})`
	elseif ClientState.getEquippedPet() then
		hintLabel.Text = `Press {keyName(keys.ToggleMount)} to ride · follow the compass to find eggs`
	else
		local untamed = 0
		for _, pet in profile.pets do
			if pet.status == "Untamed" then
				untamed += 1
			end
		end
		hintLabel.Text = if untamed > 0
			then `Find the taming item for your untamed pets, then tame them in the inventory ({keyName(keys.Inventory)})`
			else "Follow the compass needle to find an egg"
	end
end

local function refreshProfile(profile)
	-- Count the currency up smoothly.
	local target = profile.currency
	local start = displayedCurrency
	task.spawn(function()
		local steps = 12
		for i = 1, steps do
			if ClientState.profile ~= profile then
				return
			end
			displayedCurrency = math.floor(start + (target - start) * (i / steps))
			currencyLabel.Text = `{Format.commas(displayedCurrency)} {GameConfig.CurrencyName}`
			task.wait(0.02)
		end
	end)

	local pet = ClientState.getEquippedPet()
	if pet then
		petLabel.Text = `{pet.displayName} · {pet.speed} studs/s`
		petLabel.TextColor3 = RarityConfig.color(pet.rarity):Lerp(Color3.new(1, 1, 1), 0.3)
	else
		petLabel.Text = "No pet equipped"
		petLabel.TextColor3 = Theme.TextDim
	end

	local compass = CompassConfig.Compasses[profile.equippedCompass]
	compassLabel.Text = if compass then compass.displayName else "No compass equipped"
	compassLabel.TextColor3 = if compass then Theme.Text else Theme.TextDim

	rideButton.instance.Visible = pet ~= nil or ClientState.mount.mounted
	refreshHint()
end

local function refreshMount(mount)
	if mount.mounted then
		rideButton.setText("Dismount")
		rideButton.setColor(Theme.Danger)
		rideButton.instance.Visible = true
	else
		rideButton.setText("Ride")
		rideButton.setColor(Theme.Success)
		rideButton.instance.Visible = ClientState.getEquippedPet() ~= nil
	end
	refreshHint()
end

function HudController.init(c)
	controllers = c
	ClientState = c.ClientState
end

function HudController.start()
	local gui = UIKit.screen("MainHUD", 1)
	HudController.gui = gui

	local stats = UIKit.new("Frame", {
		Name = "Stats",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(16, 16),
		Size = UDim2.fromOffset(250, 190),
		Parent = gui,
	}, { UIKit.list(Enum.FillDirection.Vertical, 6) })
	currencyLabel = statRow(stats, "🪙", 1, Theme.Accent)
	speedLabel = statRow(stats, "⚡", 2, Theme.Primary)
	petLabel = statRow(stats, "🐾", 3, Theme.Success)
	compassLabel = statRow(stats, "🧭", 4, Theme.Stroke)

	local menu = UIKit.new("Frame", {
		Name = "Menu",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 16),
		Size = UDim2.fromOffset(160, 100),
		Parent = gui,
	}, { UIKit.list(Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Right) })
	UIKit.button({
		Text = `Inventory [{keyName(UIConfig.Keybinds.Inventory)}]`,
		Size = UDim2.fromOffset(160, 42),
		LayoutOrder = 1,
		Parent = menu,
	}, function()
		controllers.InventoryController.toggle()
	end)
	UIKit.button({
		Text = `Shop [{keyName(UIConfig.Keybinds.Shop)}]`,
		Color = Theme.Accent,
		Size = UDim2.fromOffset(160, 42),
		LayoutOrder = 2,
		Parent = menu,
	}, function()
		controllers.ShopController.toggle()
	end)

	rideButton = UIKit.button({
		Name = "Ride",
		Text = "Ride",
		Color = Theme.Success,
		TextSize = 20,
		Size = UDim2.fromOffset(140, 52),
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -150),
		Parent = gui,
	}, function()
		controllers.MountInputController.toggleMount()
	end)
	rideButton.instance.Visible = false

	hintLabel = UIKit.label({
		Name = "Hint",
		Text = "",
		TextSize = 15,
		TextColor3 = Theme.Text,
		TextStrokeTransparency = 0.5,
		TextXAlignment = Enum.TextXAlignment.Left,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -16),
		Size = UDim2.new(0.4, 0, 0, 40),
		Parent = gui,
	})
	refreshHint()

	ClientState.ProfileChanged:Connect(refreshProfile)
	ClientState.MountChanged:Connect(refreshMount)
	if ClientState.profile then
		refreshProfile(ClientState.profile)
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == UIConfig.Keybinds.Inventory then
			controllers.InventoryController.toggle()
		elseif input.KeyCode == UIConfig.Keybinds.Shop then
			controllers.ShopController.toggle()
		end
	end)

	-- Speed readout: actual measured speed of the character (or mount) in studs/second.
	task.spawn(function()
		while true do
			task.wait(0.1)
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local speed = if root and root:IsA("BasePart") then root.AssemblyLinearVelocity.Magnitude else 0
			local mount = ClientState.mount
			if mount.mounted then
				speedLabel.Text = `{math.floor(speed + 0.5)} / {mount.speed} studs/s`
			else
				speedLabel.Text = Format.speed(speed)
			end
		end
	end)
end

return HudController
