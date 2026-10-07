--!strict
--[[
	EscapeDoor
	Path: ServerScriptService.Server.Classes.EscapeDoor

	The physical Escape Door that opens during Extraction. Two ProximityPrompts
	(engine-validated distance) let players choose:
		"ESCAPE TO THE LOBBY"  (keyboard E, gamepad X)
		"CONTINUE"             (keyboard F, gamepad Y)
	Prompt text is dynamic: the escape prompt shows the current Candy payout, the
	continue prompt shows the next danger multiplier. All decisions are forwarded to
	EscapeService, which enforces one decision per player.

	Dependencies: MatchConfig, Format, ModelFactory, Janitor

	API:
		EscapeDoor.new(match, cframe, onDecision(player, decision)) -> EscapeDoor
		door:SetPromptText(payoutCandies, nextDanger)
		door:GetPosition() -> Vector3
		door:Destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Format = require(Shared.Utilities.Format)
local Janitor = require(Shared.Classes.Janitor)
local MatchConfig = require(Shared.Config.MatchConfig)

local Server = script:FindFirstAncestor("Server") :: Instance
local ModelFactory = require(Server.Systems.ModelFactory)

local EscapeDoor = {}
EscapeDoor.__index = EscapeDoor

local function createPrompt(parent: Instance, name: string, actionText: string, key: Enum.KeyCode, gamepad: Enum.KeyCode): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = name
	prompt.ActionText = actionText
	prompt.KeyboardKeyCode = key
	prompt.GamepadKeyCode = gamepad
	prompt.HoldDuration = 0.6
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = MatchConfig.Interaction.DoorRange
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt.Parent = parent
	return prompt
end

function EscapeDoor.new(match: any, cframe: CFrame, onDecision: (Player, string) -> ())
	local self = setmetatable({}, EscapeDoor)
	self.Janitor = Janitor.new()
	self.Position = cframe.Position

	local model = ModelFactory.CreateDoor()
	model:PivotTo(cframe)
	self.Model = self.Janitor:Add(model)

	local portal = model:FindFirstChild("Portal") :: BasePart
	local escapeAnchor = portal:FindFirstChild("EscapeAnchor") :: Attachment
	local continueAnchor = portal:FindFirstChild("ContinueAnchor") :: Attachment

	self.EscapePrompt = createPrompt(escapeAnchor, "EscapePrompt", "ESCAPE TO THE LOBBY", Enum.KeyCode.E, Enum.KeyCode.ButtonX)
	self.ContinuePrompt = createPrompt(continueAnchor, "ContinuePrompt", "CONTINUE", Enum.KeyCode.F, Enum.KeyCode.ButtonY)

	self.Janitor:Connect(self.EscapePrompt.Triggered, function(player: Player)
		onDecision(player, "Escape")
	end)
	self.Janitor:Connect(self.ContinuePrompt.Triggered, function(player: Player)
		onDecision(player, "Continue")
	end)

	model.Parent = match.Folder
	return self
end

function EscapeDoor:SetPromptText(payoutCandies: number, nextDanger: number)
	self.EscapePrompt.ObjectText = `Bank {Format.Commas(payoutCandies)} Candies`
	self.ContinuePrompt.ObjectText = `Danger {Format.Multiplier(nextDanger)}`
end

function EscapeDoor:GetPosition(): Vector3
	return self.Position
end

function EscapeDoor:Destroy()
	self.Janitor:Destroy()
end

return EscapeDoor
