-- Hatch reveal: egg wobble, flash, then the pet with its rarity colour and odds. Purely
-- presentational: the reward was already committed on the server before HatchResult was
-- sent, and the animation only displays that payload. Results queue if several arrive.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = ReplicatedStorage:WaitForChild("Config")
local EggConfig = require(Config:WaitForChild("EggConfig"))
local RarityConfig = require(Config:WaitForChild("RarityConfig"))
local UIConfig = require(Config:WaitForChild("UIConfig"))
local UIKit = require(script.Parent.UIKit)
local PetPreview = require(script.Parent.PetPreview)

local Theme = UIKit.Theme
local Settings = UIConfig.Hatch

local HatchController = {}

local Net

local gui: ScreenGui
local queue: { any } = {}
local playing = false

local function waitForContinue(button: UIKit.Button, seconds: number)
	local done = false
	local connection = button.instance.Activated:Connect(function()
		done = true
	end)
	local started = os.clock()
	while not done and os.clock() - started < seconds do
		task.wait(0.05)
	end
	connection:Disconnect()
end

local function play(result)
	local rarityRank = RarityConfig.rank(result.rarity)
	local rarityColor = RarityConfig.color(result.rarity)
	local eggTier = EggConfig.Tiers[result.eggTier]
	local eggColor = if eggTier then eggTier.color else Theme.Accent
	local isRare = rarityRank >= 5

	UIKit.clear(gui)
	gui.Enabled = true

	local backdrop = UIKit.new("Frame", {
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	UIKit.tween(backdrop, 0.3, { BackgroundTransparency = 0.35 })

	local stage = UIKit.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.9, 0.9),
		Parent = gui,
	}, { UIKit.new("UIAspectRatioConstraint", { AspectRatio = 520 / 560 }) })
	UIKit.new("UISizeConstraint", { MaxSize = Vector2.new(520, 560), Parent = stage })

	-- Egg wobble.
	local egg = UIKit.new("Frame", {
		BackgroundColor3 = eggColor,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.38),
		Size = UDim2.fromOffset(150, 190),
		Parent = stage,
	}, { UIKit.corner(80), UIKit.stroke(Color3.new(1, 1, 1), 3, 0.4) })
	local shakes = if isRare then Settings.RareShakeCount else Settings.ShakeCount
	for i = 1, shakes do
		local angle = if i % 2 == 0 then -14 else 14
		UIKit.tween(egg, Settings.ShakeTime / 2, { Rotation = angle }, Enum.EasingStyle.Sine).Completed:Wait()
		UIKit.tween(egg, Settings.ShakeTime / 2, { Rotation = 0 }, Enum.EasingStyle.Sine).Completed:Wait()
		task.wait(0.08)
	end

	-- Flash.
	local flash = UIKit.new("Frame", {
		BackgroundColor3 = if isRare then rarityColor else Color3.new(1, 1, 1),
		BackgroundTransparency = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	egg:Destroy()
	UIKit.tween(flash, 0.6, { BackgroundTransparency = 1 })
	task.delay(0.65, function()
		flash:Destroy()
	end)

	-- Reveal card.
	local cardFrame = UIKit.panel({
		BackgroundColor3 = Theme.Background,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Parent = stage,
	})
	local stroke = cardFrame:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = rarityColor
		stroke.Thickness = if isRare then 4 else 2.5
		stroke.Transparency = 0
	end
	local scale = UIKit.new("UIScale", { Scale = 0.6, Parent = cardFrame })
	UIKit.tween(scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)

	local rainbow: RBXScriptConnection? = nil
	if rarityRank >= 6 and stroke then
		local hue = 0
		rainbow = RunService.RenderStepped:Connect(function(dt)
			hue = (hue + dt * 0.4) % 1
			stroke.Color = Color3.fromHSV(hue, 0.8, 1)
		end)
	end

	local previewBox = UIKit.new("Frame", {
		BackgroundColor3 = rarityColor,
		BackgroundTransparency = 0.85,
		Position = UDim2.fromScale(0.08, 0.06),
		Size = UDim2.fromScale(0.84, 0.46),
		Parent = cardFrame,
	}, { UIKit.corner(14) })
	PetPreview.create(previewBox, result.species, true)

	UIKit.label({
		Text = if result.rarity == "Secret" then "SECRET DISCOVERY!" else "You hatched",
		Font = Theme.FontBold,
		TextSize = 16,
		TextColor3 = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0, 0.54),
		Size = UDim2.new(1, 0, 0.05, 0),
		Parent = cardFrame,
	})
	UIKit.label({
		Text = result.displayName,
		Font = Theme.FontBlack,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0.05, 0.59),
		Size = UDim2.fromScale(0.9, 0.08),
		Parent = cardFrame,
	})
	UIKit.label({
		Text = string.upper(RarityConfig.displayName(result.rarity)),
		Font = Theme.FontBlack,
		TextSize = 22,
		TextColor3 = rarityColor,
		TextStrokeTransparency = 0.6,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0, 0.68),
		Size = UDim2.new(1, 0, 0.05, 0),
		Parent = cardFrame,
	})
	UIKit.label({
		Text = result.oddsText,
		TextSize = 15,
		TextColor3 = Theme.Text,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0, 0.735),
		Size = UDim2.new(1, 0, 0.04, 0),
		Parent = cardFrame,
	})
	local itemLine = `Untamed · find a {result.requiredItemName} to tame it`
	if result.itemDropped then
		itemLine ..= " (one dropped nearby!)"
	end
	UIKit.label({
		Text = itemLine,
		TextSize = 14,
		TextColor3 = Theme.Warning,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromScale(0.05, 0.78),
		Size = UDim2.fromScale(0.9, 0.06),
		Parent = cardFrame,
	})
	local continueButton = UIKit.button({
		Text = if result.coins and result.coins > 0 then `Awesome! (+{result.coins} coins)` else "Awesome!",
		Color = Theme.Success,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.fromOffset(240, 46),
		Parent = cardFrame,
	})

	waitForContinue(continueButton, Settings.AutoCloseSeconds)
	if rainbow then
		rainbow:Disconnect()
	end
	UIKit.tween(backdrop, 0.2, { BackgroundTransparency = 1 })
	UIKit.tween(scale, 0.2, { Scale = 0.8 })
	task.wait(0.2)
	UIKit.clear(gui)
	gui.Enabled = false
end

local function drain()
	if playing then
		return
	end
	playing = true
	while #queue > 0 do
		local result = table.remove(queue, 1)
		local ok, err = pcall(play, result)
		if not ok then
			warn(`[Hatch] reveal failed: {err}`)
			UIKit.clear(gui)
			gui.Enabled = false
		end
	end
	playing = false
end

function HatchController.init(c)
	Net = c.Net
end

function HatchController.start()
	gui = UIKit.screen("HatchUI", 10, true)
	gui.Enabled = false
	-- UIKit.screen adds an AutoScale UIScale; the reveal uses scale-based layout instead.
	UIKit.clear(gui)
	Net.on("HatchResult", function(result)
		if type(result) ~= "table" or type(result.species) ~= "string" then
			return
		end
		table.insert(queue, result)
		task.spawn(drain)
	end)
end

return HatchController
