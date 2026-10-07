--!strict
--[[
	NotificationController
	Path: StarterPlayerScripts.Client.Controllers.NotificationController

	Toast notifications (ScreenGui "NotificationUI"). Shows server Notify events and
	client-side results (failed purchases etc.). Up to MAX_TOASTS stack at once; older
	ones are pushed out.

	API:
		NotificationController:Notify(text, kind?, duration?)     kind: Info|Success|Warning|Error
		NotificationController:ShowResult(result, successText?)   maps ResultCode -> message
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local ResultCode = require(Shared.Constants.ResultCode)

local Client = script:FindFirstAncestor("Client") :: Instance
local Controllers = require(Client.Modules.ControllerRegistry)
local Net = require(Client.Modules.Net)
local UIKit = require(Client.Modules.UIKit)

local MAX_TOASTS = 4
local KIND_COLORS = {
	Info = UIKit.Palette.Info,
	Success = UIKit.Palette.Good,
	Warning = UIKit.Palette.Warning,
	Error = UIKit.Palette.Bad,
}

local NotificationController = {}

local container: Frame
local order = 0

function NotificationController:Init()
	local screen = UIKit.Screen("NotificationUI", 20)
	container = UIKit.Create("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.2, 0),
		Size = UDim2.new(0.5, 0, 0.5, 0),
		BackgroundTransparency = 1,
		Parent = screen,
	}, {
		UIKit.Create("UISizeConstraint", { MaxSize = Vector2.new(520, math.huge) }),
		UIKit.List(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top),
	})
end

function NotificationController:Start()
	Net:On("Notify", function(payload)
		if type(payload) == "table" and type(payload.Text) == "string" then
			self:Notify(payload.Text, payload.Kind, payload.Duration)
		end
	end)
end

function NotificationController:Notify(text: string, kind: string?, duration: number?)
	order += 1
	local color = KIND_COLORS[kind or "Info"] or KIND_COLORS.Info
	local toast = UIKit.Panel({
		Name = "Toast",
		Size = UDim2.new(1, 0, 0, 44),
		LayoutOrder = order,
		BackgroundColor3 = UIKit.Palette.Panel,
		Parent = container,
	})
	UIKit.Create("Frame", {
		Name = "Accent",
		Size = UDim2.new(0, 8, 1, 0),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = toast,
	}, { UIKit.Corner(8) })
	UIKit.Label({
		Size = UDim2.new(1, -24, 1, -8),
		Position = UDim2.fromOffset(16, 4),
		Text = text,
		TextXAlignment = Enum.TextXAlignment.Left,
		MaxTextSize = 20,
		Parent = toast,
	})
	if kind == "Error" or kind == "Warning" then
		Controllers.AudioController:Play(if kind == "Error" then "Error" else "Countdown")
	end

	local toasts = {}
	for _, child in container:GetChildren() do
		if child:IsA("Frame") then
			table.insert(toasts, child)
		end
	end
	table.sort(toasts, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	while #toasts > MAX_TOASTS do
		(table.remove(toasts, 1) :: Instance):Destroy()
	end

	task.delay(duration or 4, function()
		if toast.Parent then
			UIKit.Tween(toast, { BackgroundTransparency = 1 }, 0.3)
			task.wait(0.3)
			toast:Destroy()
		end
	end)
end

function NotificationController:ShowResult(result: { Ok: boolean, Code: string }, successText: string?)
	if result.Ok then
		if successText then
			self:Notify(successText, "Success", 2.5)
		end
		Controllers.AudioController:Play("Purchase")
	else
		self:Notify(ResultCode.Messages[result.Code] or "That didn't work.", "Error", 3)
	end
end

return NotificationController
