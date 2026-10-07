# 🎃 Protect the Pumpkin Farm

A Halloween co-op wave-defense + farming + extraction game for Roblox, written in Luau with a
server-authoritative architecture.

Pick a permanent costume class in the lobby, then queue for a farm with up to 3 friends. Buy seeds
with **Candies**, plant alien crops, and defend them from waves of zombies with your weapon,
barricades and sentries (bought with temporary **Match Coins**). Harvested produce goes into the
team's **Harvest Chest**. Every 5 waves the **Escape Door** opens:

- **Escape to the lobby**: the chest converts into permanent Candies.
- **Continue**: 30 s of preparation, then much harder waves. If you escape later, the payout is
  bigger. If the farm falls, the chest is lost.

Every 10th wave brings **The Cursed Harvester**.

## Quick start

```sh
cd PumpkinFarm
rojo serve default.project.json      # then click Connect in the Rojo Studio plugin
# or build a place file:
rojo build default.project.json -o PumpkinFarm.rbxl
```

Press **Play** (or start a local server with 2–4 players). You spawn in the lobby: walk through the
**Farm Portal** or press **PLAY**. No art assets are needed. Every model (enemies, crops, defenses,
weapons, the door, the map) has a procedural fallback, and UI is built in code.

Without Rojo, recreate the tree in [docs/ARCHITECTURE.md § Studio tree](docs/ARCHITECTURE.md#studio-tree)
and paste each file into a ModuleScript (`*.luau`), Script (`*.server.luau`) or LocalScript
(`*.client.luau`) with the same name.

### One-time Studio settings
| Setting | Value | Why |
|---|---|---|
| Players.CharacterAutoLoads | false | the server decides when and where players spawn (also set by Rojo and in code) |
| Workspace.StreamingEnabled | false | arenas are far from the lobby; UI binds to match folders immediately |
| Lighting.Technology | Future | the dusk lighting is tuned for it (scripts can't set this) |
| Game Settings › Security › Enable Studio Access to API Services | optional | only if you want real DataStore saves in Studio; otherwise profiles are in-memory and marked "Test mode" |

## Controls

| Action | Keyboard / mouse | Gamepad | Touch |
|---|---|---|---|
| Attack (class weapon) | Left click | R2 | Tap |
| Class ability | Q | Y | Ability button |
| Seed shop | G | HUD button | HUD button |
| Defenses & gear | B | HUD button | HUD button |
| Harvest chest | C | HUD button | HUD button |
| Quick heal (40 coins) | H | HUD button | HUD button |
| Plant / harvest / upgrade / door | E (prompt), F (upgrade, continue) | X / Y | Prompt |
| Place defense | Click, R rotate, Shift keep placing, X / right-click cancel | R2, X rotate, B cancel | Tap |
| Close panel | Esc | B | ✕ button |

Plant by selecting a seed in the seed pouch (bottom of the screen) and walking up to an empty plot slot.

## Layout

```
PumpkinFarm/
├── default.project.json        Rojo tree (ReplicatedStorage.Shared, ServerScriptService.Server, StarterPlayerScripts.Client)
├── src/shared/                 Config, Constants, Types, Utilities, Data, Classes  (ReplicatedStorage.Shared)
├── src/server/                 Bootstrap, Registry, Services, Systems, AI, Classes, Data  (ServerScriptService.Server)
├── src/client/                 ClientBootstrap, Modules, Controllers  (StarterPlayerScripts.Client)
├── tests/                      headless verification (Lune + python)
└── docs/                       ARCHITECTURE, PHASES, TESTING
```

## Documentation

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**: every service and its API, init order, state
  machines, the complete remote table, Studio object contract, data schema and migrations, security,
  performance and memory safety.
- **[docs/PHASES.md](docs/PHASES.md)**: the five engineering phases, what each one delivers, and the
  completion checklist.
- **[docs/TESTING.md](docs/TESTING.md)**: automated checks and the Studio test plan (gameplay,
  multiplayer, exploit, failure and cleanup tests), plus debug commands.

## Verification

```sh
PumpkinFarm/tests/run.sh
```
Needs [Lune](https://lune-org.github.io) (and optionally [selene](https://github.com/Kampfkarren/selene)). It
compiles all 123 source files, lints them, cross-checks every service call, `require`, remote and
effect name, and runs 221 headless specs: difficulty curves, wave composition, seed shop stock and
races, Harvest Chest payouts, profile session locking and migrations, the Mole's underground A*
router, rate limiting, purchase atomicity, escape double-payout protection, every procedural model
and map, and the whole client UI (Lune validates every Instance property name and type).

Engine behaviour (physics, pathfinding, UI) can only be exercised in Studio; follow docs/TESTING.md.
