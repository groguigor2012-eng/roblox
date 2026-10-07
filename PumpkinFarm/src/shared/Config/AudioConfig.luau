--!strict
--[[
	AudioConfig
	Path: ReplicatedStorage.Shared.Config.AudioConfig

	Sound ids for AudioController. Ids starting with "rbxasset://" ship with the Roblox
	client and work out of the box; replace them (or fill empty ids) with uploaded
	rbxassetid:// sounds without touching any code. An empty SoundId is skipped.

	Music tracks only play while the profile setting MusicEnabled is true.
]]

local TableUtil = require(script.Parent.Parent.Utilities.TableUtil)

export type SoundDefinition = { SoundId: string, Volume: number, PlaybackSpeed: number? }

local AudioConfig = {
	Sounds = {
		UIClick = { SoundId = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.35 },
		Purchase = { SoundId = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.5, PlaybackSpeed = 1.3 },
		Error = { SoundId = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.4, PlaybackSpeed = 0.6 },
		Slash = { SoundId = "rbxasset://sounds/swordslash.wav", Volume = 0.6 },
		Whirl = { SoundId = "rbxasset://sounds/swordlunge.wav", Volume = 0.7 },
		CastBolt = { SoundId = "rbxasset://sounds/Rocket shot.wav", Volume = 0.35, PlaybackSpeed = 1.6 },
		Explosion = { SoundId = "rbxasset://sounds/collide.wav", Volume = 0.6, PlaybackSpeed = 0.7 },
		Harvest = { SoundId = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.5, PlaybackSpeed = 1.6 },
		Plant = { SoundId = "rbxasset://sounds/action_jump.mp3", Volume = 0.4, PlaybackSpeed = 0.8 },
		Hurt = { SoundId = "rbxasset://sounds/uuhhh.mp3", Volume = 0.5 },
		WaveStart = { SoundId = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.7, PlaybackSpeed = 0.5 },
		BossRoar = { SoundId = "rbxasset://sounds/uuhhh.mp3", Volume = 0.9, PlaybackSpeed = 0.45 },
		Countdown = { SoundId = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.4, PlaybackSpeed = 1.1 },
	} :: { [string]: SoundDefinition },

	Music = {
		Lobby = { SoundId = "", Volume = 0.3 },
		Wave = { SoundId = "", Volume = 0.3 },
		Boss = { SoundId = "", Volume = 0.35 },
	} :: { [string]: SoundDefinition },
}

return TableUtil.DeepFreeze(AudioConfig)
