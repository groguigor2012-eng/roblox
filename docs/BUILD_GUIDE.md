# Poolrooms: Build Guide

This guide explains how the Poolrooms build works and which values to set in Studio. All of the
scripts it describes are in `src/`, and every number comes from `src/shared/Config.luau`.

---

## 1. Architectural & material setup

### Part properties (applies to every tiled surface)

| Property | Value | Why |
|---|---|---|
| `Anchored` | `true` | Static architecture |
| `Material` | `CeramicTiles` | Base material for the variant below |
| `MaterialVariant` | `"PoolTile"` | The custom white-tile look |
| `Color` | `242, 240, 232` (walls/floors) · `196, 232, 222` (inside pools) | Warm off-white; pale aqua under water |
| `Reflectance` | `0` | Gloss comes from the roughness map, not Reflectance (Reflectance only mirrors the skybox and looks like chrome) |
| `CastShadow` | `true` (`false` for glowing panels and handrails) | Soft contact shadows under Future lighting |
| `CanTouch` | `false` | Saves physics work on thousands of parts |
| `TopSurface` / `BottomSurface` | `Smooth` | No studs |
| Position / Size | Whole studs on a 1-stud grid | Keeps grout lines continuous from one part to the next |

In Studio, set **Model → Move** to `1` stud and **Rotate** to `90°` (or `15°` for curves) while building by hand.

### White square tile texture (`PoolTile` MaterialVariant)

1. Generate the maps (they're already in `assets/textures/`):
   `python tools/generate_tile_textures.py`. This produces 1024×1024 maps that tile seamlessly, with 8 × 8 tiles each:
   - `pool_tile_color.png`: glazed off-white tiles with grey-green grout
   - `pool_tile_normal.png`: bevelled tile edges and recessed grout (OpenGL / +Y)
   - `pool_tile_roughness.png`: glossy glaze (≈0.12) and matte grout (≈0.75)
2. Upload all three in **View → Asset Manager → Bulk Import**, or on the Creator Hub.
3. In **MaterialService**, insert a **MaterialVariant** and set:

| Property | Value |
|---|---|
| `Name` | `PoolTile` |
| `BaseMaterial` | `CeramicTiles` |
| `ColorMap` / `NormalMap` / `RoughnessMap` | the three uploaded ids |
| `MetalnessMap` | *(empty)* |
| `StudsPerTile` | `8` → **one tile = 1 × 1 stud** |
| `MaterialPattern` | `Regular` (a strict grid; `Organic` would break up the tiles) |

4. Optional: set `MaterialService.CeramicTilesName = "PoolTile"`. Every CeramicTiles part then uses
   the variant automatically, including parts you build by hand.

The variant has to be created in Studio, because a running script can't set a variant's texture
maps. Until it exists, parts fall back to Roblox's built-in CeramicTiles, so the game still works.

*Alternative:* add a `Texture` to each face, with `StudsPerTileU = StudsPerTileV = 8` and
the colour map. This works without MaterialService, but it needs 6 instances per part, and the
textures don't follow curves, so the MaterialVariant is the better option.

### Key geometry (`src/shared/Builders.luau`)

Everything is made from plain Parts, so the generator can build it at runtime. To try a single
piece, paste this into the Studio command bar:

```lua
local B = require(game.ReplicatedStorage.Poolrooms.Builders)
B.archway(workspace, CFrame.new(0, 0, 0), {
    totalWidth = 62, openingWidth = 44, springHeight = 6, rise = 14, height = 24, depth = 3,
})
B.spiralStair(workspace, CFrame.new(40, 0, 0), { height = 30 })
B.roundBore(workspace, CFrame.new(-40, 0, 0), { width = 28, height = 24, depth = 12, radius = 6, centerY = 3 })
```

| Feature | How it's built |
|---|---|
| **Curved archways** (`archway`) | Two piers, then vertical "spandrel" slices from the curve up to the ceiling. The slices are never wider than the arch band is thick, so no gap can show. A band of short angled segments then traces the semi-ellipse. Each segment's inner face sits on a chord of the curve, so the underside of the arch looks smooth. Repeated every 16 studs, these make the receding arch halls. |
| **Cylindrical pillars** (`pillar`) | `Shape = Cylinder`. Roblox cylinders run along the part's X axis, so the part is rotated `CFrame.Angles(0, 0, math.pi/2)` and sized `(height, 2r, 2r)`. They run from floor to ceiling, so they look structural. |
| **Spiral staircases** (`spiralStair`) | A cylinder core plus one 6-stud step every 18° and every 1 stud of rise. That gives 20 studs per full turn, enough headroom to walk under the turn above. The steps overlap slightly at the outer edge, and there are thin rail posts with a continuous handrail. The staircase climbs out of the water into a glowing ceiling shaft. |
| **Low tunnels / pipes** (`roundBore`) | A solid block with a circular bore: side masses, slices above and below the circle, and a full 360° segment lining. The lining darkens toward the back and ends at a black disk, so the tunnel seems to go on forever. |
| **Recessed alcoves** (`Joints.luau` → `alcove`) | A 4-stud-thick wall built with `wallWithHoles`, which splits the wall into the fewest rectangles around the openings. It has walk-through openings at water level and a row of blind niches higher up, each closed by a back panel 3 studs deep. |
| Doorways, floors with pool cut-outs, ceilings with light wells | `wallWithHoles` / `slabWithHoles`, which use the same rectangle-subtraction routine. |

**Avoiding z-fighting:** two faces must never sit in the same plane facing the same way. The
builders handle this as follows:
- Pool walls stop 1 stud below the floor top.
- Arch bands are inset 0.05 studs.
- Every other band segment is 0.04 studs thinner.
- Light-well shafts start above the ceiling slab.
- Corner piers are 5 studs wide, so they never match the face of a 4-stud wall.

`tests/run.sh` checks every layout for this automatically.

---

## 2. Lighting & atmosphere (`src/server/WorldSetup.server.luau`)

**Set this one by hand in Studio:** `Lighting.Technology = Future`. Scripts can't change it at
runtime. If you use Rojo, `default.project.json` sets it for you. Future lighting gives the
skylights soft, shadow-casting light. If Future is too heavy for low-end devices, `ShadowMap` is
the fallback.

| Lighting | Value | | Effect | Value |
|---|---|---|---|---|
| `Brightness` | 3 | | **Atmosphere** `Density` | 0.38 |
| `ClockTime` | 13 | | `Offset` | 0.2 |
| `Ambient` | 150, 160, 156 | | `Haze` | 1.8 |
| `OutdoorAmbient` | 205, 212, 208 | | `Glare` | 0.4 |
| `ColorShift_Top` | 255, 248, 232 | | `Color` / `Decay` | 214,236,230 / 176,214,204 |
| `ColorShift_Bottom` | 200, 236, 228 | | **ColorCorrection** `Brightness` | 0.04 |
| `ExposureCompensation` | **0.6** (overexposed look) | | `Contrast` | −0.08 |
| `EnvironmentDiffuseScale` | 1 | | `Saturation` | −0.12 |
| `EnvironmentSpecularScale` | 1 | | `TintColor` | 244, 255, 251 |
| `ShadowSoftness` | 0.6 | | **Bloom** `Intensity / Size / Threshold` | 0.65 / 40 / 0.92 |
| `GlobalShadows` | true | | **SunRays** `Intensity / Spread` | 0.06 / 0.8 |
| | | | **DepthOfField** `Far / Focus / InFocus` | 0.18 / 28 / 45 |

**Diffused daylight from hidden openings.** Most rooms have a square **light well** cut into the
ceiling. A short tiled shaft rises out of sight to a white Neon panel. On that panel, a downward
`SurfaceLight` (Brightness 3, Range 48, Angle 80, Shadows on) floods the room. The Neon panel
blooms, so the opening reads as a bright window to daylight. The **Atrium** room is open to the
real sky, so actual sunlight and SunRays fall into its pool through a shaft lined with glowing
windows.

The high `Ambient`, the slightly negative `Contrast` and `ExposureCompensation` together stop the
shadows from going dark, which is what makes the place feel dreamlike. Atmosphere haze also hides
chunks as they load in at the edge of view.

---

## 3. Water

### Recommendation: Smooth Terrain water

| | Terrain water ✅ | Transparent Parts |
|---|---|---|
| Swimming / buoyancy | Built in | ❌ Characters walk through it |
| Waves, refraction, underwater fog | Built in | ❌ |
| Surface reflections | Sky + specular highlights | Reflectance only mirrors the skybox |
| Colour per pool | ❌ Global (`Terrain.WaterColor`) | ✅ |

Neither option produces real-time mirror reflections of nearby geometry; Roblox doesn't support
that. Terrain water is still clearly better, because the deep pools need real swimming. The
pristine look comes from very transparent water over white and aqua tiles: shallow water looks
almost clear, and deep pools turn teal.

**Settings** (Color3; Roblox colours are `Color3`, not `Vector3`):

```lua
Terrain.WaterColor        = Color3.fromRGB(72, 186, 170)  -- turquoise / teal
Terrain.WaterTransparency = 0.85   -- crystal clear; tiles visible through it
Terrain.WaterReflectance  = 0.45   -- soft sheen without hiding the floor
Terrain.WaterWaveSize     = 0.04   -- near-still
Terrain.WaterWaveSpeed    = 3
```

**Voxel alignment.** Terrain is stored in 4-stud voxels. A water volume that ends partway
through a voxel gets a wobbly surface. To keep every surface flat:
- The water surface is at `Y = 0`, and the tiled floor is 2 studs below it at `Y = −2`.
- Each chunk fills exactly one voxel row, from −4 to 0. The floor part hides the lower half.
- Deep pools go down to `Y = −16`.
- Every water region starts and ends on multiples of 4.

The result is ankle-deep wading water across the whole map, which never triggers swimming,
plus deep pools you can swim in.

*If you still want a part-based decorative sheet:* `Material = Glass`, `Color = 95, 200, 185`,
`Transparency = 0.55`, `Reflectance = 0.1`, `CanCollide = false`. Use it only where nobody needs to swim.

---

## 4. Seamless procedural generation (`src/server/PoolroomGenerator.server.luau`)

**Grid.** Chunk `(i, j)` is a 64 × 64 stud cell centred at `(i·64, j·64)`. The chunk size, the
floor and water heights, and every pool are multiples of 4, so parts and terrain line up exactly
at every border.

**Layouts** (`src/shared/Chunks.luau`) fill only a chunk's interior, staying 8 studs away from its
borders:

| Layout | Feature from your brief |
|---|---|
| `DeepPool` | Open deep pool with pool steps, stepping platforms and corner pillars |
| `ArchedHall` | Four receding curved archways over shallow water |
| `SunkenStair` | A grand staircase descending into a deep pool that drains into a submerged tunnel |
| `SpiralRoom` | A spiral staircase rising into a light shaft beside a half-flooded pipe |
| `ColumnHall` | Large columns standing in wide open water, sometimes with a sunken basin |
| `Atrium` | A shaft open to the sky with glowing windows, above a deep pool |
| `Spawn` | A calm column hall at the origin |

**Joints** (`src/shared/Joints.luau`) are the walls, archways, doors and alcoves on each border,
plus a square pier at every corner. They're keyed by the border itself (for example
`X:3:-2`), so two neighbouring chunks always share one wall and never build two.
Each joint is reference-counted, and it's removed only when both of its chunks unload.

**Determinism.** Layouts and border styles come from `Hash(Config.SEED, i, j)`, not from the
order in which chunks happen to load. Every server builds the same world, and a room you leave
looks the same when you come back.

**Connectivity guarantee.** Each chunk has a "parent" border that points one step toward the
origin, and that border is always passable. Together these borders form a tree that reaches
every chunk, so no room can ever be sealed off. `tests/run.sh` checks this over a 41 × 41 area.

**Streaming.** Every 0.5 s, the generator:
1. Loads every missing chunk within `LOAD_RADIUS` (2, a 5 × 5 area) of each player and of the spawn, nearest first, one per frame so the game doesn't hitch.
2. Unloads chunks beyond `UNLOAD_RADIUS` (3) and clears their terrain water.

**Adding a room:** write `Layouts.MyRoom = function(ctx) ... end` in `Chunks.luau` and add it to
`Weights`. Inside a layout, build relative to `ctx.frame`, where y = 0 is the floor top. Use
`addPit` for pools, `addLightWell` for skylights, and stay within ±24 studs of the centre.

---

## 5. Player controls & camera (`src/client/`)

**`FirstPersonCamera.client.luau`**
- `CameraMode = LockFirstPerson` and `FieldOfView = 74`.
- The head-bob runs at render priority `Camera + 1`, so it is applied after Roblox's camera has
  updated each frame:
  - **Walking:** two small dips per stride (0.09 studs), a 0.05-stud side sway and a 0.35° roll.
  - **Swimming:** one slow 0.16-stud rise and fall per stroke.
  - **Standing still:** a faint breathing motion.
- The bob fades in and out smoothly. It only offsets and rolls the camera, so it never changes
  where you're looking.

**Walking pace:** `StarterPlayer.CharacterWalkSpeed = 11` (the Roblox default is 16). Swimming
runs at 80% of that.

**`WaterMovement.client.luau`**
- Reads the terrain voxel at the character's feet to tell whether you're **wading**.
- While wading, it mutes the default tile footstep and plays a soft splash every 3.4 studs with
  a slightly random pitch.
- While **swimming**, it plays a gentle stroke splash every 1.1 s.
- Jumping or falling into water plays a bigger splash.
- `SoundService.AmbientReverb = Bathroom` makes every sound echo off the tile.
- To add a looping ambience track, set `Config.AMBIENT_SOUND_ID`.

The splash sounds use Roblox's built-in `rbxasset://sounds/impact_water.mp3` and
`action_swim.mp3`, so they work without uploading anything. They're created on the client, so
each player hears only their own splashes; other players' default swim sounds still play.

---

## Known limitations
- Roblox has no real-time planar reflections, so pillars aren't mirrored in the water the way they are in the reference images.
- About 1,500 parts per 3 × 3 chunks. On low-end phones, lower `LOAD_RADIUS` to 1 and raise Atmosphere `Density` to hide the shorter view distance.
- Tiles on curved surfaces (pillars, arch bands) don't wrap the curve as cleanly as on flat walls.
