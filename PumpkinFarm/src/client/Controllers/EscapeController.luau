--!strict
--[[
	EscapeController
	Path: StarterPlayerScripts.Client.Controllers.EscapeController

	ScreenGui "EscapeUI", shown while the Escape Door is open:
		* countdown to the decision deadline
		* "ESCAPE TO THE LOBBY" (+ Candies you would bank) and "CONTINUE" (+ the next
		  danger level and enemy health multiplier) buttons
		* the buttons work within MatchConfig.Interaction.DoorRange of the door (the
		  same rule the server enforces); otherwise the panel points you to the door
		* after choosing, both buttons lock and show your decision; teammates'
		  decisions are listed
	The physical door's ProximityPrompts do the same thing; both paths hit
	EscapeService.SubmitDecision, which accepts one decision per player.

	API: none (self-contained)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Clock = require(Shared.Utilities.Clock)
local Format = require(Shared.Utilities.Format)
local MatchConfig = require(Shared.Config.MatchConfig)

local Client = script:FindFirstAncestor("Client") :: Instance
local ClientState = require(Client.Modules.ClientState)
local Controllers = require(Client.Modules.ControllerRegistry)
local Net = require(Client.Modules.Net)
local UIKit = require(Client.Modules.UIKit)

local player = Players.LocalPlayer
local Palette = UIKit.Palette

local EscapeController = {}

local ui: { [string]: any } = {}
local deciding = false

function EscapeController:Init()
	local screen = UIKit.Screen("EscapeUI", 12)
	ui.Screen = screen
	local frame = UIKit.Panel({
		Name = "EscapePanel",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -90),
		Size = UDim2.fromOffset(560, 210),
		BackgroundColor3 = Color3.fromRGB(40, 16, 60),
		Visible = false,
		Parent = screen,
	})
	ui.Frame = frame
	ui.Title = UIKit.Label({
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -24, 0, 34),
		Text = "🚪 THE ESCAPE DOOR IS OPEN",
		Font = UIKit.Fonts.Title,
		TextColor3 = Palette.AlienTeal,
		MaxTextSize = 28,
		Parent = frame,
	})
	ui.Timer = UIKit.Label({
		Position = UDim2.fromOffset(12, 40),
		Size = UDim2.new(1, -24, 0, 24),
		Text = "",
		MaxTextSize = 20,
		Parent = frame,
	})
	ui.Escape = UIKit.Button({
		Position = UDim2.fromOffset(12, 70),
		Size = UDim2.new(0.5, -18, 0, 84),
		Text = "ESCAPE TO THE LOBBY",
		Color = Palette.Good,
		MaxTextSize = 22,
		OnClick = function()
			EscapeController:Decide("RequestEscape")
		end,
		Parent = frame,
	})
	ui.Continue = UIKit.Button({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 70),
		Size = UDim2.new(0.5, -18, 0, 84),
		Text = "CONTINUE",
		Color = Palette.Bad,
		MaxTextSize = 22,
		OnClick = function()
			EscapeController:Decide("RequestContinue")
		end,
		Parent = frame,
	})
	ui.Footer = UIKit.Label({
		Position = UDim2.fromOffset(12, 160),
		Size = UDim2.new(1, -24, 0, 42),
		Text = "",
		Font = UIKit.Fonts.Light,
		MaxTextSize = 16,
		Parent = frame,
	})
end

local function distanceToDoor(extraction: any): number
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root == nil or extraction.DoorPosition == nil then
		return math.huge
	end
	return (root.Position - extraction.DoorPosition).Magnitude
end

function EscapeController:Decide(remote: string)
	local extraction = ClientState.Extraction
	if deciding or extraction == nil or not extraction.Open or extraction.YourDecision ~= nil then
		return
	end
	if distanceToDoor(extraction) > MatchConfig.Interaction.DoorRange then
		Controllers.NotificationController:Notify("Walk to the Escape Door first!", "Warning", 2)
		return
	end
	deciding = true
	task.spawn(function()
		local result = Net:Invoke(remote)
		deciding = false
		Controllers.NotificationController:ShowResult(result, if remote == "RequestEscape" then nil else "You chose to CONTINUE. Brace yourself!")
	end)
end

local function refresh()
	local extraction = ClientState.Extraction
	local open = extraction ~= nil and extraction.Open == true and ClientState.InMatch()
	ui.Frame.Visible = open
	if not open then
		return
	end
	ui.Escape.Text = `ESCAPE TO THE LOBBY\n<font size="18">Bank {Format.Commas(extraction.EstimatedCandies or 0)} 🍬</font>`
	ui.Continue.Text = `CONTINUE\n<font size="18">Danger {Format.Roman(extraction.NextContinueLevel or 1)} • zombies {Format.Multiplier(extraction.NextHealthMultiplier or 1)}</font>`

	local names = {}
	for userIdText, decision in extraction.Decisions or {} do
		local other = Players:GetPlayerByUserId(tonumber(userIdText) or 0)
		table.insert(names, `{other and other.DisplayName or "?"}: {decision}`)
	end
	local mine = extraction.YourDecision
	local near = distanceToDoor(extraction) <= MatchConfig.Interaction.DoorRange
	local locked = mine ~= nil
	ui.Escape.Active = near and not locked
	ui.Continue.Active = near and not locked
	ui.Escape.AutoButtonColor = false
	ui.Escape.BackgroundTransparency = if near and not locked then 0 else 0.5
	ui.Continue.BackgroundTransparency = if near and not locked then 0 else 0.5

	local footer = if locked
		then `You chose <b>{mine}</b>. Waiting for the team...`
		elseif near then "Choose wisely: continuing raises the danger, but escaping later pays more."
		else `Walk to the Escape Door ({math.floor(distanceToDoor(extraction))} studs) to choose.`
	if #names > 0 then
		footer ..= "\n" .. table.concat(names, "  •  ")
	end
	ui.Footer.Text = footer
end

function EscapeController:Start()
	ClientState.ExtractionChanged:Connect(refresh)
	ClientState.MatchChanged:Connect(refresh)
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 0.2 then
			return
		end
		accumulator = 0
		local extraction = ClientState.Extraction
		if extraction and extraction.Open then
			ui.Timer.Text = `Decide in {Format.Countdown((extraction.DeadlineAt or 0) - Clock.Now())} • undecided players follow the team`
			refresh()
		end
	end)
end

return EscapeController
