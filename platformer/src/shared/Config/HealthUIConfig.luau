--!strict
-- Heart display and damage feedback. Hearts are a view of Humanoid.Health:
--   perHeart        = MaxHealth / HeartCount
--   remainingHearts = clamp(ceil(Health / perHeart), 0, HeartCount)
-- With MaxHealth 100 and 3 hearts the boundaries are 66.67 and 33.33.

local HealthUIConfig = {}

HealthUIConfig.HeartCount = 3

HealthUIConfig.Layout = table.freeze({
	-- Top-left anchored panel.
	Position = UDim2.new(0, 18, 0, 18),
	HeartSize = 40, -- pixels at scale 1
	HeartSpacing = 8,
	-- Fill heart size relative to its outline heart.
	FillScale = 0.76,
	CountTextSize = 22,
	PanelPadding = 10,
	CornerRadius = 12,
	DisplayOrder = 5,
	-- UIScale = clamp(viewportHeight / ReferenceHeight, MinScale, MaxScale).
	ReferenceHeight = 900,
	MinScale = 0.75,
	MaxScale = 1.35,
})

HealthUIConfig.Style = table.freeze({
	Font = Enum.Font.GothamBold,
	PanelColor = Color3.fromRGB(16, 18, 26),
	PanelTransparency = 0.25,
	PanelStrokeColor = Color3.fromRGB(230, 234, 245),
	PanelStrokeTransparency = 0.6,
	OutlineColor = Color3.fromRGB(236, 238, 245),
	FilledColor = Color3.fromRGB(214, 48, 66),
	EmptyColor = Color3.fromRGB(46, 48, 60),
	TextColor = Color3.fromRGB(240, 242, 248),
	-- Fill scale for an empty heart (a slightly shrunken dark heart).
	EmptyScale = 0.85,
	TransitionTime = 0.18,
	-- Outline scale reached by the "pop" when a heart is lost or regained.
	PopScale = 1.18,
})

-- Hides Roblox's default health bar, but only after the custom UI built
-- successfully, so a failure never leaves the player without health feedback.
HealthUIConfig.DisableDefaultHealthBar = true

HealthUIConfig.DamageFeedback = table.freeze({
	-- Health drops smaller than this are ignored (regen jitter).
	MinDamage = 0.5,
	FlashColor = Color3.fromRGB(200, 20, 30),
	-- Overlay opacity at intensity 1 (overlay transparency = 1 - this * intensity).
	FlashMaxOpacity = 0.45,
	FlashDuration = 0.35,
	-- intensity = clamp(FlashBaseIntensity + damageFraction * FlashIntensityPerHealthFraction, 0, 1)
	FlashBaseIntensity = 0.35,
	FlashIntensityPerHealthFraction = 1.5,
	FlashDisplayOrder = 50,
	-- Camera shake uses "trauma" in [0, 1]:
	--   offset = MaxOffset * trauma^2 * noise(t * Frequency)
	--   trauma -= TraumaDecayPerSecond * dt
	-- Trauma is capped at 1, so a burst of hits can never exceed MaxOffset
	-- or last longer than 1 / TraumaDecayPerSecond seconds.
	ShakeBaseTrauma = 0.3,
	ShakeTraumaPerHealthFraction = 1.2,
	ShakeMaxOffset = 0.55,
	ShakeFrequency = 22,
	TraumaDecayPerSecond = 2.8,
})

return table.freeze(HealthUIConfig)
