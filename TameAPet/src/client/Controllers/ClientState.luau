-- Read-only mirror of server state for the UI. Everything here arrives from the server
-- (ProfileSync, MountState, CompassTarget) and is only used for display; requests always go
-- back through validated remotes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Signal"))

local ClientState = {}

ClientState.profile = nil :: any -- ProfileView from the server, nil until loaded
ClientState.mount = { mounted = false } :: any
ClientState.compassTarget = nil :: any

ClientState.ProfileChanged = Signal.new() -- (profile)
ClientState.MountChanged = Signal.new() -- (mountState)
ClientState.CompassTargetChanged = Signal.new() -- (target)

local Net

function ClientState.isLoaded(): boolean
	return ClientState.profile ~= nil
end

function ClientState.getPet(petId: string): any?
	local profile = ClientState.profile
	if not profile then
		return nil
	end
	for _, pet in profile.pets do
		if pet.id == petId then
			return pet
		end
	end
	return nil
end

function ClientState.getEquippedPet(): any?
	local profile = ClientState.profile
	if not profile or profile.equippedPetId == "" then
		return nil
	end
	return ClientState.getPet(profile.equippedPetId)
end

function ClientState.itemCount(itemId: string): number
	local profile = ClientState.profile
	if not profile then
		return 0
	end
	for _, item in profile.items do
		if item.id == itemId then
			return item.quantity
		end
	end
	return 0
end

function ClientState.ownsCompass(compassId: string): boolean
	local profile = ClientState.profile
	return profile ~= nil and table.find(profile.compasses, compassId) ~= nil
end

local function setProfile(profile)
	if type(profile) ~= "table" then
		return
	end
	ClientState.profile = profile
	ClientState.ProfileChanged:Fire(profile)
end

function ClientState.init(controllers)
	Net = controllers.Net
end

function ClientState.start()
	Net.on("ProfileSync", setProfile)
	Net.on("MountState", function(state)
		if type(state) ~= "table" then
			return
		end
		ClientState.mount = state
		ClientState.MountChanged:Fire(state)
	end)
	Net.on("CompassTarget", function(target)
		if type(target) ~= "table" then
			return
		end
		ClientState.compassTarget = target
		ClientState.CompassTargetChanged:Fire(target)
	end)

	-- The server pushes a sync as soon as the profile loads; ask as well in case that push
	-- happened before these listeners were connected.
	task.spawn(function()
		for _ = 1, 30 do
			if ClientState.profile then
				return
			end
			local result = Net.invoke("RequestSync")
			if result.ok and result.data then
				if not ClientState.profile then
					setProfile(result.data)
				end
				return
			end
			task.wait(2)
		end
	end)
end

return ClientState
