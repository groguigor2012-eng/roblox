--!strict
-- Central tuning values for the Poolrooms. Every dimension here is in studs.
--
-- Grid rules that keep chunks seamless:
--   * CHUNK_SIZE is a multiple of 4, so chunk borders land on terrain voxel borders.
--   * FLOOR_Y / WATER_Y / pool depths are multiples of 2 / 4, so terrain water fills
--     whole voxels and the water surface is perfectly flat at WATER_Y.

local Config = {}

Config.SEED = 1337 -- same seed = same world layout every server

-- Grid ---------------------------------------------------------------------
Config.CHUNK_SIZE = 64
Config.LOAD_RADIUS = 2 -- chunks loaded around each player (2 => 5x5 area)
Config.UNLOAD_RADIUS = 3 -- chunks farther than this from every player are removed
Config.UPDATE_INTERVAL = 0.5 -- seconds between generator passes
Config.CHUNKS_PER_STEP = 1 -- chunks built per frame (spreads out part creation)

-- Vertical layout ----------------------------------------------------------
Config.FLOOR_Y = -2 -- top surface of the tiled floor
Config.FLOOR_THICKNESS = 1
Config.WATER_Y = 0 -- water surface (2 studs of shallow water over the floor)
Config.CEILING_Y = 22 -- underside of the ceiling (24 studs of headroom)
Config.CEILING_THICKNESS = 2
Config.DEEP_FLOOR_Y = -16 -- bottom of deep pools
Config.EDGE_MARGIN = 8 -- interior features keep this far from chunk borders

-- Walls --------------------------------------------------------------------
Config.WALL_THICKNESS = 2
Config.THICK_WALL = 4 -- walls with recessed alcoves

-- Materials ----------------------------------------------------------------
-- Parts use CeramicTiles + the "PoolTile" MaterialVariant. If you have not created
-- the variant yet (see docs/BUILD_GUIDE.md), parts fall back to plain CeramicTiles.
Config.TILE_MATERIAL = Enum.Material.CeramicTiles
Config.TILE_VARIANT = "PoolTile"
Config.TILE_COLOR = Color3.fromRGB(242, 240, 232) -- warm off-white
Config.POOL_TILE_COLOR = Color3.fromRGB(196, 232, 222) -- pale aqua tiles inside pools
Config.VOID_COLOR = Color3.fromRGB(4, 8, 8) -- the dark at the end of tunnels
Config.LIGHT_PANEL_COLOR = Color3.fromRGB(255, 252, 240)

-- Water (Terrain) ------------------------------------------------------------
Config.WATER_COLOR = Color3.fromRGB(72, 186, 170)
Config.WATER_TRANSPARENCY = 0.85
Config.WATER_REFLECTANCE = 0.45
Config.WATER_WAVE_SIZE = 0.04
Config.WATER_WAVE_SPEED = 3

-- Lighting -------------------------------------------------------------------
Config.SKYLIGHT_BRIGHTNESS = 3
Config.SKYLIGHT_RANGE = 48
Config.SKYLIGHT_SHADOWS = true

-- Player ---------------------------------------------------------------------
Config.WALK_SPEED = 11 -- default Roblox is 16; slower feels more liminal
Config.SWIM_SPEED_MULTIPLIER = 0.8
Config.FIELD_OF_VIEW = 74

-- Optional sound ids (leave "" to skip). Splash sounds use Roblox built-ins.
Config.AMBIENT_SOUND_ID = "" -- e.g. a looping water/hum ambience you uploaded
Config.SPLASH_STEP_SOUND = "rbxasset://sounds/impact_water.mp3"
Config.SWIM_STROKE_SOUND = "rbxasset://sounds/action_swim.mp3"

return Config
