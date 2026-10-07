--!strict
--[[
	Panels
	Path: StarterPlayerScripts.Client.Modules.Panels

	Keeps modal panels (seed shop, defenses, chest, wardrobe, upgrades) mutually
	exclusive: opening one closes the others, and Escape / gamepad B closes the top one.
	World ProximityPrompts with an "OpensUI" attribute (wardrobe, upgrade stand, harvest
	chest) open the panel of that name when triggered.

	API:
		Panels.Register(name, frame, onOpen?, onClose?)
		Panels.Open(name) / Panels.Close(name) / Panels.Toggle(name)
		Panels.IsOpen(name) -> boolean
		Panels.CloseAll()
		Panels.Changed : Signal(name, isOpen)
]]

local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Classes"):WaitForChild("Signal"))

type PanelEntry = { Frame: GuiObject, OnOpen: (() -> ())?, OnClose: (() -> ())? }

local Panels = {}
Panels.Changed = Signal.new()

local registry: { [string]: PanelEntry } = {}
local openName: string? = nil

function Panels.Register(name: string, frame: GuiObject, onOpen: (() -> ())?, onClose: (() -> ())?)
	registry[name] = { Frame = frame, OnOpen = onOpen, OnClose = onClose }
	frame.Visible = false
end

function Panels.IsOpen(name: string): boolean
	return openName == name
end

function Panels.Close(name: string)
	local entry = registry[name]
	if entry == nil or openName ~= name then
		return
	end
	entry.Frame.Visible = false
	openName = nil
	if entry.OnClose then
		entry.OnClose()
	end
	Panels.Changed:Fire(name, false)
end

function Panels.CloseAll()
	if openName then
		Panels.Close(openName)
	end
end

function Panels.Open(name: string)
	local entry = registry[name]
	if entry == nil then
		return
	end
	if openName and openName ~= name then
		Panels.Close(openName)
	end
	openName = name
	entry.Frame.Visible = true
	if entry.OnOpen then
		entry.OnOpen()
	end
	Panels.Changed:Fire(name, true)
end

function Panels.Toggle(name: string)
	if openName == name then
		Panels.Close(name)
	else
		Panels.Open(name)
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
		Panels.CloseAll()
	end
end)

ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt)
	local name = prompt:GetAttribute("OpensUI")
	if type(name) == "string" then
		Panels.Open(name)
	end
end)

return Panels
