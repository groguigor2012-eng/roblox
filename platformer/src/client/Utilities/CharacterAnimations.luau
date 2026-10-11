--!strict
-- Plays AnimationConfig entries on the local character's existing Animator
-- (the one Roblox's Humanoid/Animate setup already uses), so custom tracks
-- blend with the default idle/walk/jump animations by priority.
--
--   * Each track is loaded once per character and cached; the Animation
--     instance and the track are added to the character's cleanup group, so
--     a respawn never reuses or leaks a track.
--   * Ids are preloaded with ContentProvider. An id that fails to load (bad
--     id, wrong owner, moderated) is reported once and treated as not
--     configured for the rest of the session, so callers use their fallback.
--   * Tracks played by the local Animator replicate to other players
--     automatically; nothing here sends per-frame data.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AnimationConfig = require(Shared:WaitForChild("Config"):WaitForChild("AnimationConfig"))
local Logger = require(Shared:WaitForChild("Utilities"):WaitForChild("Logger"))

local CharacterLifecycle = require(script.Parent.CharacterLifecycle)

type Entry = AnimationConfig.Entry
type Context = CharacterLifecycle.Context

local logger = Logger.new("CharacterAnimations")

local CharacterAnimations = {}

local tracksByContext: { [Context]: { [string]: AnimationTrack } } = {}
local unavailable: { [string]: boolean } = {}
local preloaded: { [string]: boolean } = {}

local function markUnavailable(id: string, reason: string)
	if not unavailable[id] then
		unavailable[id] = true
		logger:Warn("AnimationUnavailable", { Id = id, Reason = reason, Effect = "using fallback" })
	end
end

-- True when the entry has an id that has not failed to load.
function CharacterAnimations.IsAvailable(entry: Entry): boolean
	return entry.AnimationId ~= "" and not unavailable[entry.AnimationId]
end

-- Starts downloading configured animations in the background.
function CharacterAnimations.Preload(entries: { Entry })
	local animations: { Instance } = {}
	for _, entry in entries do
		local id = entry.AnimationId
		if id ~= "" and not preloaded[id] then
			preloaded[id] = true
			local animation = Instance.new("Animation")
			animation.AnimationId = id
			table.insert(animations, animation)
		end
	end
	if #animations == 0 then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(animations, function(assetId: string, status: Enum.AssetFetchStatus)
				if status ~= Enum.AssetFetchStatus.Success then
					markUnavailable(assetId, `preload status {status.Name}`)
				end
			end)
		end)
		if not ok then
			logger:Warn("PreloadFailed", { Error = err })
		end
		for _, animation in animations do
			animation:Destroy()
		end
	end)
end

local function getTrack(context: Context, entry: Entry): AnimationTrack?
	local cache = tracksByContext[context]
	if not cache then
		cache = {}
		tracksByContext[context] = cache
		context.Cleanup:Add(function()
			tracksByContext[context] = nil
		end)
	end
	local id = entry.AnimationId
	local cached = cache[id]
	if cached then
		return cached
	end

	local animator = context.Humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil -- not created yet; the caller falls back this time
	end
	local animation = context.Cleanup:Add(Instance.new("Animation"))
	animation.AnimationId = id
	local ok, result = pcall(animator.LoadAnimation, animator, animation)
	if not ok then
		markUnavailable(id, tostring(result))
		return nil
	end
	local track = result :: AnimationTrack
	track.Priority = entry.Priority
	track.Looped = entry.Looped
	context.Cleanup:Add(function()
		track:Stop(0)
		track:Destroy()
	end)
	cache[id] = track
	return track
end

-- Plays the entry on this character. Returns the track, or nil when the
-- entry is not configured/available or the Animator is missing (callers
-- then use their fallback). A track that is already playing is left alone,
-- so the same animation never overlaps itself.
function CharacterAnimations.Play(context: Context, entry: Entry): AnimationTrack?
	if not CharacterAnimations.IsAvailable(entry) or not context.Alive then
		return nil
	end
	local track = getTrack(context, entry)
	if not track then
		return nil
	end
	if not track.IsPlaying then
		track:Play(entry.FadeTime, 1, entry.Speed)
	end
	return track
end

return CharacterAnimations
