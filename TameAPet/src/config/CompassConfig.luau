--!strict
-- Compasses and the compass HUD's tuning values.

export type CompassDefinition = {
	displayName: string,
	description: string,
	maxRange: number, -- studs; eggs further away are ignored
	minTier: string, -- lowest egg rarity this compass reacts to
	color: Color3,
	order: number,
}

local CompassConfig = {}

CompassConfig.Compasses = {
	BasicCompass = {
		displayName = "Wooden Compass",
		description = "Points at the nearest egg within 500 studs.",
		maxRange = 500,
		minTier = "Common",
		color = Color3.fromRGB(176, 128, 84),
		order = 1,
	},
	ExplorerCompass = {
		displayName = "Explorer's Compass",
		description = "A finely tuned needle that senses eggs up to 1500 studs away.",
		maxRange = 1500,
		minTier = "Common",
		color = Color3.fromRGB(90, 190, 255),
		order = 2,
	},
	PrismCompass = {
		displayName = "Prism Compass",
		description = "Ignores ordinary eggs and hunts Rare or better across the whole map.",
		maxRange = 2500,
		minTier = "Rare",
		color = Color3.fromRGB(220, 120, 255),
		order = 3,
	},
} :: { [string]: CompassDefinition }

CompassConfig.Tracking = {
	-- Server: how often each player's nearest target is recomputed.
	TargetRefreshInterval = 0.5,
	-- Client: how quickly the needle eases towards its target angle (per second).
	NeedleLerpSpeed = 10,
	-- Glow ramps from GlowTransparencyFar (at MaxGlowDistance or more) to
	-- GlowTransparencyNear (at 0 studs).
	MaxGlowDistance = 250,
	GlowTransparencyFar = 0.92,
	GlowTransparencyNear = 0.15,
	StrokeThicknessFar = 2,
	StrokeThicknessNear = 7,
	-- Distances at or below this show "Right here!" instead of a number.
	ArrivedDistance = 12,
	DistanceDecimalsOver = 1000, -- above this, show 1.2k studs
	DistanceUnit = "studs",
	-- When nothing is in range the needle drifts slowly and the dial dims.
	NoTargetText = "No eggs in range",
	NoTargetSpinSpeed = 25, -- degrees per second
}

return CompassConfig
