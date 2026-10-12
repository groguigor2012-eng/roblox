-- Client entry point: requires every controller, then runs init() on all of them (wiring
-- only), then start() in order (build UI, connect remotes). UI shows a loading state until
-- the server's first ProfileSync arrives.

local root = script.Parent
local Controllers = root:WaitForChild("Controllers")
local UIControllers = root:WaitForChild("UIControllers")
local InputControllers = root:WaitForChild("InputControllers")

local ORDER = {
	{ "Net", Controllers:WaitForChild("Net") },
	{ "ClientState", Controllers:WaitForChild("ClientState") },
	{ "NotificationController", UIControllers:WaitForChild("NotificationController") },
	{ "HudController", UIControllers:WaitForChild("HudController") },
	{ "CompassController", Controllers:WaitForChild("CompassController") },
	{ "InventoryController", UIControllers:WaitForChild("InventoryController") },
	{ "ShopController", UIControllers:WaitForChild("ShopController") },
	{ "HatchController", UIControllers:WaitForChild("HatchController") },
	{ "MountInputController", InputControllers:WaitForChild("MountInputController") },
}

local controllers = {}
for _, entry in ORDER do
	controllers[entry[1]] = require(entry[2])
end
for _, entry in ORDER do
	controllers[entry[1]].init(controllers)
end
for _, entry in ORDER do
	local ok, err = pcall(controllers[entry[1]].start)
	if not ok then
		warn(`[Client] {entry[1]} failed to start: {err}`)
	end
end
