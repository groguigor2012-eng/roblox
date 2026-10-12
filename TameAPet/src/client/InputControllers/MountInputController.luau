-- Mount controls for keyboard, gamepad and touch. While riding, sends normalised movement
-- intent (forward/turn/vertical in [-1, 1] + jump) to the server, only when it changes or as a
-- keep-alive, at most MountConfig.InputSendRate times per second. The server owns the physics.
--
-- Keyboard: WASD/arrows steer, Space jump/climb, LeftControl or Q descend/land, R ride/dismount.
-- Touch: thumbstick steers; on-screen Up/Down buttons; HUD "Ride/Dismount" button.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = ReplicatedStorage:WaitForChild("Config")
local MountConfig = require(Config:WaitForChild("MountConfig"))
local UIConfig = require(Config:WaitForChild("UIConfig"))

local player = Players.LocalPlayer
local Keys = UIConfig.Keybinds

local MountInputController = {}

local ClientState
local Net
local Notify

local controls: any = nil
local ascendHeld = false
local descendHeld = false
local loop: RBXScriptConnection? = nil
local lastSent = { forward = 0, turn = 0, vertical = 0, jump = false }
local lastSendAt = 0
local requestPending = false

local ACTION_ASCEND = "TameAPet_MountAscend"
local ACTION_DESCEND = "TameAPet_MountDescend"
local ACTION_TOGGLE = "TameAPet_ToggleMount"

local function getMoveVector(): Vector3
	if controls then
		local ok, vector = pcall(function()
			return controls:GetMoveVector()
		end)
		if ok and typeof(vector) == "Vector3" then
			return vector
		end
	end
	-- Fallback when the default PlayerModule has been replaced.
	local x, z = 0, 0
	if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up) then
		z -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down) then
		z += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left) then
		x -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then
		x += 1
	end
	return Vector3.new(x, 0, z)
end

local function quantise(value: number): number
	return math.floor(math.clamp(value, -1, 1) * 20 + 0.5) / 20
end

local function sendInput(force: boolean)
	local move = getMoveVector()
	local current = {
		forward = quantise(-move.Z),
		turn = quantise(move.X),
		vertical = (if ascendHeld then 1 else 0) - (if descendHeld then 1 else 0),
		jump = ascendHeld,
	}
	local now = os.clock()
	local changed = current.forward ~= lastSent.forward
		or current.turn ~= lastSent.turn
		or current.vertical ~= lastSent.vertical
		or current.jump ~= lastSent.jump
	local minInterval = 1 / MountConfig.InputSendRate
	if now - lastSendAt < minInterval then
		return
	end
	if not (force or changed or now - lastSendAt >= MountConfig.InputKeepAlive) then
		return
	end
	lastSent = current
	lastSendAt = now
	Net.fire("MountInput", current.forward, current.turn, current.vertical, current.jump)
end

local function setJumpEnabled(enabled: boolean)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, enabled)
	end
end

local function onVertical(actionName: string, state: Enum.UserInputState): Enum.ContextActionResult
	local held = state == Enum.UserInputState.Begin
	if state == Enum.UserInputState.Cancel then
		held = false
	end
	if actionName == ACTION_ASCEND then
		ascendHeld = held
	else
		descendHeld = held
	end
	sendInput(true)
	return Enum.ContextActionResult.Sink
end

local function startRiding(mount)
	ascendHeld, descendHeld = false, false
	setJumpEnabled(false)
	local priority = Enum.ContextActionPriority.High.Value
	ContextActionService:BindActionAtPriority(ACTION_ASCEND, onVertical, true, priority, Keys.Ascend, Enum.KeyCode.ButtonA)
	ContextActionService:SetTitle(ACTION_ASCEND, if mount.canFly then "Up" else "Jump")
	ContextActionService:SetPosition(ACTION_ASCEND, UDim2.new(1, -95, 1, -170))
	if mount.canFly then
		ContextActionService:BindActionAtPriority(
			ACTION_DESCEND,
			onVertical,
			true,
			priority,
			Keys.Descend,
			Keys.DescendAlt,
			Enum.KeyCode.ButtonB
		)
		ContextActionService:SetTitle(ACTION_DESCEND, "Down")
		ContextActionService:SetPosition(ACTION_DESCEND, UDim2.new(1, -170, 1, -110))
	end
	if not loop then
		loop = RunService.Heartbeat:Connect(function()
			sendInput(false)
		end)
	end
end

local function stopRiding()
	ascendHeld, descendHeld = false, false
	ContextActionService:UnbindAction(ACTION_ASCEND)
	ContextActionService:UnbindAction(ACTION_DESCEND)
	if loop then
		loop:Disconnect()
		loop = nil
	end
	lastSent = { forward = 0, turn = 0, vertical = 0, jump = false }
	setJumpEnabled(true)
end

function MountInputController.toggleMount()
	if requestPending then
		return
	end
	requestPending = true
	local result
	if ClientState.mount.mounted then
		result = Net.invoke("Dismount")
	else
		result = Net.invoke("SummonMount")
	end
	requestPending = false
	Notify.showResult(result)
end

function MountInputController.init(c)
	ClientState = c.ClientState
	Net = c.Net
	Notify = c.NotificationController
end

function MountInputController.start()
	task.spawn(function()
		local ok, module = pcall(function()
			local playerModule = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10)
			-- The default PlayerModule is inserted by Roblox at runtime, so it is required dynamically.
			return (require :: any)(playerModule)
		end)
		if ok and module then
			controls = module:GetControls()
		else
			warn("[Mount] PlayerModule unavailable; using keyboard fallback for mount steering")
		end
	end)

	ContextActionService:BindAction(ACTION_TOGGLE, function(_, state)
		if state == Enum.UserInputState.Begin then
			task.spawn(MountInputController.toggleMount)
		end
		return Enum.ContextActionResult.Sink
	end, false, Keys.ToggleMount, Enum.KeyCode.ButtonY)

	ClientState.MountChanged:Connect(function(mount)
		if mount.mounted then
			startRiding(mount)
		else
			stopRiding()
		end
	end)
	player.CharacterAdded:Connect(function()
		if not ClientState.mount.mounted then
			setJumpEnabled(true)
		end
	end)
end

return MountInputController
