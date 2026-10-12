-- Toast notifications (top centre). Repeats of a visible message are merged into one toast
-- with a counter, the stack is capped, and rate-limited requests never produce a toast.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Config")
local UIConfig = require(Config:WaitForChild("UIConfig"))
local RarityConfig = require(Config:WaitForChild("RarityConfig"))
local UIKit = require(script.Parent.UIKit)

local Theme = UIKit.Theme
local Settings = UIConfig.Notifications

local NotificationController = {}

local Net
local container: Frame
local order = 0
local visible: { { text: string, frame: Frame, count: number, label: TextLabel, expires: number } } = {}

local KIND_COLORS = {
	info = Theme.Primary,
	success = Theme.Success,
	error = Theme.Danger,
	coin = Theme.Accent,
	rare = Theme.Accent,
}

local function removeEntry(entry)
	local index = table.find(visible, entry)
	if index then
		table.remove(visible, index)
	end
	local frame = entry.frame
	UIKit.tween(frame, 0.25, { BackgroundTransparency = 1 })
	UIKit.tween(entry.label, 0.25, { TextTransparency = 1 })
	task.delay(0.26, function()
		frame:Destroy()
	end)
end

function NotificationController.show(kind: string, text: string, rarity: string?)
	if type(text) ~= "string" or text == "" then
		return
	end
	local now = os.clock()
	local duration = if kind == "rare" then Settings.RareDuration else Settings.Duration

	for _, entry in visible do
		if entry.text == text then
			entry.count += 1
			entry.label.Text = `{text}  x{entry.count}`
			entry.expires = now + duration
			return
		end
	end

	while #visible >= Settings.MaxVisible do
		removeEntry(visible[1])
	end

	local accent = KIND_COLORS[kind] or Theme.Primary
	if rarity then
		accent = RarityConfig.color(rarity)
	end
	order += 1
	local frame = UIKit.new("Frame", {
		BackgroundColor3 = Theme.Background,
		BackgroundTransparency = 0.1,
		Size = UDim2.fromOffset(460, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = container,
	}, {
		UIKit.corner(10),
		UIKit.stroke(accent, 2, 0.1),
		UIKit.new("UIPadding", {
			PaddingTop = UDim.new(0, 10),
			PaddingBottom = UDim.new(0, 10),
			PaddingLeft = UDim.new(0, 18),
			PaddingRight = UDim.new(0, 14),
		}),
	})
	UIKit.new("Frame", {
		BackgroundColor3 = accent,
		BorderSizePixel = 0,
		Position = UDim2.new(0, -12, 0, 0),
		Size = UDim2.new(0, 4, 1, 0),
		Parent = frame,
	}, { UIKit.corner(2) })
	local label = UIKit.label({
		Text = text,
		Font = if kind == "rare" then Theme.FontBlack else Theme.FontBold,
		TextSize = if kind == "rare" then 18 else 16,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = frame,
	})

	local entry = { text = text, frame = frame, count = 1, label = label, expires = now + duration }
	table.insert(visible, entry)
	frame.Position = UDim2.fromOffset(0, -10)
	UIKit.tween(frame, 0.2, { Position = UDim2.fromOffset(0, 0) }, Enum.EasingStyle.Back)
end

-- Standard handling for request results: errors are shown, rate-limit/busy are silent.
function NotificationController.showResult(result, successText: string?)
	if result.ok then
		if successText then
			NotificationController.show("success", successText)
		end
		return
	end
	if result.code == "RateLimited" or result.code == "Busy" then
		return
	end
	NotificationController.show("error", result.message or "That didn't work. Try again.")
end

function NotificationController.init(controllers)
	Net = controllers.Net
end

function NotificationController.start()
	local gui = UIKit.screen("NotificationsUI", 20)
	container = UIKit.new("Frame", {
		Name = "Toasts",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 70),
		Size = UDim2.fromOffset(460, 400),
		Parent = gui,
	}, { UIKit.list(Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Center) })

	Net.on("Notify", function(payload)
		if type(payload) == "table" then
			NotificationController.show(payload.kind, payload.text, payload.rarity)
		end
	end)

	-- One timer expires toasts (no per-toast threads).
	task.spawn(function()
		while true do
			task.wait(0.25)
			local now = os.clock()
			for i = #visible, 1, -1 do
				local entry = visible[i]
				if entry and now >= entry.expires then
					removeEntry(entry)
				end
			end
		end
	end)
end

return NotificationController
