# Poolrooms

An infinite, procedurally generated **Poolrooms** for Roblox: white-tiled liminal halls filled
with still, turquoise water, lit by soft daylight from openings you can't quite see.

You explore it in first person. It includes:
- open deep pools
- halls of receding archways
- staircases sinking into flooded tunnels
- spiral stairs climbing into the light
- forests of columns standing in the water

See **[docs/BUILD_GUIDE.md](docs/BUILD_GUIDE.md)** for the full breakdown: materials, lighting
values, the water setup, how the generator works, and camera and controls.

## Setup

### With Rojo (recommended)
```sh
rojo serve default.project.json   # then click Connect in the Rojo Studio plugin
# or build a place file:
rojo build default.project.json -o Poolrooms.rbxl
```

### Without Rojo
Recreate this hierarchy in Studio, pasting in each file's contents:

| Studio location | Type | Source |
|---|---|---|
| `ReplicatedStorage/Poolrooms/{Config, Builders, Hash, Joints, Chunks}` | ModuleScript | `src/shared/*.luau` |
| `ServerScriptService/Poolrooms/{WorldSetup, PoolroomGenerator}` | Script | `src/server/*.server.luau` |
| `StarterPlayer/StarterPlayerScripts/Poolrooms/{FirstPersonCamera, WaterMovement}` | LocalScript | `src/client/*.client.luau` |

### Two one-time steps in Studio
1. **Lighting → Technology = Future.** Scripts can't set this; Rojo users already have it.
2. **Tile texture:** upload `assets/textures/*.png` and create the `PoolTile` MaterialVariant
   (see the guide, section 1). Without it, the build uses Roblox's default CeramicTiles.

Press **Play** and you spawn in a column hall at the origin.

## Layout
```
src/shared/   Config, geometry Builders, Hash, Joints (shared walls), Chunks (room layouts)
src/server/   WorldSetup (lighting/water), PoolroomGenerator (chunk streaming)
src/client/   FirstPersonCamera (head-bob), WaterMovement (wading/swimming sounds)
assets/       generated tile textures      tools/  texture generator
tests/        headless geometry + connectivity checks (Lune)
```

## Tests
```sh
tests/run.sh   # needs Lune: https://lune-org.github.io
```
These run outside Roblox. They build every room layout and every border style and check for:
- zero-size parts and parts that spill outside their chunk
- z-fighting (two overlapping faces in the same plane)
- that every chunk within 20 of the spawn can be reached
