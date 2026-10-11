--!strict
-- Owns a group of resources and releases them together, newest first.
--
-- Accepted resources:
--   RBXScriptConnection -> Disconnect()
--   Tween               -> Cancel() then Destroy()
--   Instance            -> Destroy()
--   thread              -> task.cancel() (skipped if it is the running thread)
--   function            -> called
--   table with :Destroy() -> called
--
-- Errors raised while releasing are reported with warn() and never stop the
-- remaining resources from being released.
--
-- Lives in Shared (not Server/Utilities) because client controllers use it too.

export type ResourceCleanup = {
	Add: <T>(self: ResourceCleanup, resource: T) -> T,
	Connect: (self: ResourceCleanup, signal: RBXScriptSignal, callback: (...any) -> ()) -> RBXScriptConnection,
	Clean: (self: ResourceCleanup) -> (),
	Destroy: (self: ResourceCleanup) -> (),
	IsDestroyed: (self: ResourceCleanup) -> boolean,
	_name: string,
	_resources: { any },
	_destroyed: boolean,
}

local ResourceCleanup = {}
ResourceCleanup.__index = ResourceCleanup

function ResourceCleanup.new(name: string?): ResourceCleanup
	local self = {
		_name = name or "ResourceCleanup",
		_resources = {},
		_destroyed = false,
	}
	return (setmetatable(self, ResourceCleanup) :: any) :: ResourceCleanup
end

local function release(name: string, resource: any)
	local kind = typeof(resource)
	local ok, err: any = true, nil
	if kind == "RBXScriptConnection" then
		resource:Disconnect()
	elseif kind == "Instance" then
		ok, err = pcall(function()
			if resource:IsA("Tween") then
				resource:Cancel()
			end
			resource:Destroy()
		end)
	elseif kind == "thread" then
		if resource ~= coroutine.running() and coroutine.status(resource) ~= "dead" then
			ok, err = pcall(task.cancel, resource)
		end
	elseif kind == "function" then
		ok, err = pcall(resource)
	elseif kind == "table" and type(resource.Destroy) == "function" then
		ok, err = pcall(resource.Destroy, resource)
	else
		ok, err = false, `unsupported resource type {kind}`
	end
	if not ok then
		warn(`[Platformer/ResourceCleanup] {name}: failed to release {kind}: {err}`)
	end
end

-- Adds a resource and returns it. Adding to a destroyed group releases the
-- resource immediately, so late async work cannot leak.
function ResourceCleanup.Add<T>(self: ResourceCleanup, resource: T): T
	if self._destroyed then
		release(self._name, resource)
		return resource
	end
	table.insert(self._resources, resource)
	return resource
end

function ResourceCleanup.Connect(
	self: ResourceCleanup,
	signal: RBXScriptSignal,
	callback: (...any) -> ()
): RBXScriptConnection
	return self:Add(signal:Connect(callback))
end

-- Releases everything added so far. The group stays usable.
function ResourceCleanup.Clean(self: ResourceCleanup)
	local resources = self._resources
	self._resources = {}
	for index = #resources, 1, -1 do
		release(self._name, resources[index])
	end
end

-- Releases everything and makes later Add calls release immediately.
function ResourceCleanup.Destroy(self: ResourceCleanup)
	self._destroyed = true
	self:Clean()
end

function ResourceCleanup.IsDestroyed(self: ResourceCleanup): boolean
	return self._destroyed
end

return ResourceCleanup
