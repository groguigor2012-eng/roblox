--!strict
--[[
	ClientState
	Path: StarterPlayerScripts.Client.Modules.ClientState

	Single read-only cache of server-replicated state for all controllers:
	  * Profile / Shop / Chest / Extraction tables from their remotes (+ a snapshot
	    request on start and whenever the player enters a match, so nothing is missed)
	  * the player's current match folder (workspace.Matches.Match_<MatchId>), bound
	    from the Player "MatchId" attribute
	  * ObserveMatchAttribute: subscribe to a match-folder attribute; survives match
	    changes (the callback receives nil while not in a match)

	Display only. The server never trusts any of this.

	API:
		ClientState.Profile / .Shop / .Chest / .Extraction / .MatchFolder
		ClientState.ProfileChanged / ShopChanged / ChestChanged / ExtractionChanged / MatchChanged : Signal
		ClientState.Start()
		ClientState.GetMatchAttribute(name) -> any
		ClientState.ObserveMatchAttribute(name, callback) -> () -> ()   (returns unsubscribe)
		ClientState.InMatch() -> boolean
		ClientState.RefreshSnapshot()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared:WaitForChild("Constants"):WaitForChild("Attributes"))
local Signal = require(Shared:WaitForChild("Classes"):WaitForChild("Signal"))

local Net = require(script.Parent.Net)

local player = Players.LocalPlayer

type Observer = { Name: string, Callback: (any) -> (), Connection: RBXScriptConnection? }

local ClientState = {
	Profile = nil :: any,
	Shop = nil :: any,
	Chest = nil :: any,
	Extraction = nil :: any,
	MatchFolder = nil :: Folder?,
	ProfileChanged = Signal.new(),
	ShopChanged = Signal.new(),
	ChestChanged = Signal.new(),
	ExtractionChanged = Signal.new(),
	MatchChanged = Signal.new(),
}

local observers: { Observer } = {}
local bindToken = 0

local function connectObserver(observer: Observer)
	if observer.Connection then
		observer.Connection:Disconnect()
		observer.Connection = nil
	end
	local folder = ClientState.MatchFolder
	if folder then
		observer.Connection = folder:GetAttributeChangedSignal(observer.Name):Connect(function()
			observer.Callback(folder:GetAttribute(observer.Name))
		end)
		observer.Callback(folder:GetAttribute(observer.Name))
	else
		observer.Callback(nil)
	end
end

local function setMatchFolder(folder: Folder?)
	if ClientState.MatchFolder == folder then
		return
	end
	ClientState.MatchFolder = folder
	for _, observer in observers do
		connectObserver(observer)
	end
	ClientState.MatchChanged:Fire(folder)
end

local function bindMatch()
	bindToken += 1
	local token = bindToken
	local matchId = player:GetAttribute(Attributes.MatchId)
	if matchId == nil then
		setMatchFolder(nil)
		ClientState.Shop = nil
		ClientState.Chest = nil
		ClientState.Extraction = nil
		ClientState.ShopChanged:Fire(nil)
		ClientState.ChestChanged:Fire(nil)
		ClientState.ExtractionChanged:Fire(nil)
		return
	end
	task.spawn(function()
		local matches = Workspace:WaitForChild("Matches", 30)
		local folder = matches and matches:WaitForChild(`Match_{matchId}`, 30)
		if token ~= bindToken then
			return
		end
		setMatchFolder(folder :: Folder?)
		ClientState.RefreshSnapshot()
	end)
end

function ClientState.RefreshSnapshot()
	task.spawn(function()
		local result = Net:Invoke("RequestSnapshot")
		if not result.Ok or result.Data == nil then
			return
		end
		local data = result.Data
		if data.Profile then
			ClientState.Profile = data.Profile
			ClientState.ProfileChanged:Fire(data.Profile)
		end
		ClientState.Shop = data.Shop
		ClientState.ShopChanged:Fire(data.Shop)
		ClientState.Chest = data.Chest
		ClientState.ChestChanged:Fire(data.Chest)
		ClientState.Extraction = data.Extraction
		ClientState.ExtractionChanged:Fire(data.Extraction)
	end)
end

function ClientState.InMatch(): boolean
	return ClientState.MatchFolder ~= nil
end

function ClientState.GetMatchAttribute(name: string): any
	local folder = ClientState.MatchFolder
	return folder and folder:GetAttribute(name)
end

function ClientState.ObserveMatchAttribute(name: string, callback: (any) -> ()): () -> ()
	local observer: Observer = { Name = name, Callback = callback, Connection = nil }
	table.insert(observers, observer)
	connectObserver(observer)
	return function()
		local index = table.find(observers, observer)
		if index then
			table.remove(observers, index)
		end
		if observer.Connection then
			observer.Connection:Disconnect()
		end
	end
end

function ClientState.Start()
	Net:On("ProfileUpdated", function(profile)
		ClientState.Profile = profile
		ClientState.ProfileChanged:Fire(profile)
	end)
	Net:On("ShopUpdated", function(shop)
		ClientState.Shop = shop
		ClientState.ShopChanged:Fire(shop)
	end)
	Net:On("ChestUpdated", function(chest)
		ClientState.Chest = chest
		ClientState.ChestChanged:Fire(chest)
	end)
	Net:On("ExtractionUpdated", function(extraction)
		ClientState.Extraction = extraction
		ClientState.ExtractionChanged:Fire(extraction)
	end)
	player:GetAttributeChangedSignal(Attributes.MatchId):Connect(bindMatch)
	bindMatch()
	ClientState.RefreshSnapshot()
end

return ClientState
