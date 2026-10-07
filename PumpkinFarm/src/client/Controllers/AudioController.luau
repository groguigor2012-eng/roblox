--!strict
--[[
	AudioController
	Path: StarterPlayerScripts.Client.Controllers.AudioController

	Plays UI/combat sounds and state music from AudioConfig. Sound ids are data: swap
	them in AudioConfig without touching code; empty ids are skipped. Respects the
	persisted profile settings MusicEnabled / EffectsEnabled.

	API:
		AudioController:Play(soundName)
		AudioController:SetMusic(trackName?)        -- "Lobby" | "Wave" | "Boss" | nil
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage.Shared
local AudioConfig = require(Shared.Config.AudioConfig)
local Attributes = require(Shared.Constants.Attributes)
local MatchState = require(Shared.Constants.MatchState)

local Client = script:FindFirstAncestor("Client") :: Instance
local ClientState = require(Client.Modules.ClientState)
local Net = require(Client.Modules.Net)

local AudioController = {}

local soundFolder: Folder
local sounds: { [string]: Sound } = {}
local musicSound: Sound
local currentTrack: string? = nil

local function settingEnabled(key: string): boolean
	local profile = ClientState.Profile
	if profile and profile.Settings and profile.Settings[key] == false then
		return false
	end
	return true
end

function AudioController:Init()
	soundFolder = Instance.new("Folder")
	soundFolder.Name = "PumpkinFarmSounds"
	soundFolder.Parent = SoundService
	for name, definition in AudioConfig.Sounds do
		if definition.SoundId ~= "" then
			local sound = Instance.new("Sound")
			sound.Name = name
			sound.SoundId = definition.SoundId
			sound.Volume = definition.Volume
			sound.PlaybackSpeed = definition.PlaybackSpeed or 1
			sound.Parent = soundFolder
			sounds[name] = sound
		end
	end
	musicSound = Instance.new("Sound")
	musicSound.Name = "Music"
	musicSound.Looped = true
	musicSound.Parent = soundFolder
end

function AudioController:Play(soundName: string)
	if not settingEnabled("EffectsEnabled") then
		return
	end
	local sound = sounds[soundName]
	if sound then
		SoundService:PlayLocalSound(sound)
	end
end

function AudioController:SetMusic(trackName: string?)
	if trackName == currentTrack then
		return
	end
	currentTrack = trackName
	musicSound:Stop()
	local definition = trackName and AudioConfig.Music[trackName]
	if definition == nil or definition.SoundId == "" or not settingEnabled("MusicEnabled") then
		return
	end
	musicSound.SoundId = definition.SoundId
	musicSound.Volume = definition.Volume
	musicSound:Play()
end

function AudioController:Start()
	local function refreshMusic(state: string?)
		if state == nil then
			self:SetMusic("Lobby")
		elseif state == MatchState.BossWave then
			self:SetMusic("Boss")
		elseif state == MatchState.WaveActive then
			self:SetMusic("Wave")
		end
	end
	ClientState.ObserveMatchAttribute(Attributes.State, refreshMusic)
	ClientState.ProfileChanged:Connect(function()
		local track = currentTrack
		currentTrack = nil
		self:SetMusic(track)
	end)
	Net:On("MatchEvent", function(eventName: string)
		if eventName == "WaveStarted" then
			self:Play("WaveStart")
		elseif eventName == "BossSpawned" then
			self:Play("BossRoar")
		end
	end)
end

return AudioController
