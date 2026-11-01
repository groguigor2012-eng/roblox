# THE SHUTTER: Camcorder core, Dual-Reality rendering (System B), and The Watcher AI (System E)

This folder is a standalone Roblox project. It contains three pieces that depend on each other:

| Piece | What it does |
|---|---|
| **Core: Camcorder & Battery** | Server-owned camcorder state, battery drain and recharge, walk/sprint/film speeds, anti-speed check, validated look direction |
| **System B: Dual-Reality Rendering** | `CameraOnly` content appears only while filming. `NakedEyeOnly` content appears only while not filming. Also includes the analog viewfinder HUD and server-validated hidden doors and pickups |
| **System E: The Watcher** | Server AI that freezes while any camcorder films it, and otherwise stalks, hunts, relocates and catches players |

## Download & open in Studio (fastest)

1. Download **[`build/TheShutter.rbxlx`](build/TheShutter.rbxlx)**. On GitHub, open the file and click *Download raw file*.
2. In Roblox Studio, choose **File → Open from File…** and pick `TheShutter.rbxlx`.
3. Press **Play**. A demo level builds itself and the Watcher starts walking toward you.

To add THE SHUTTER to an **existing place**, use the three model files in `build/` instead (see Part 4).

---

## PART 1: System architecture

```
 CLIENT (untrusted)                                  SERVER (authoritative)
 ─────────────────                                   ──────────────────────
 CamcorderController ── CamcorderToggle(bool) ──────▶ CamcorderService
   F / L2 / "CAM" btn     SprintState(bool) ────────▶   • raise allowed? (alive, battery ≥ 5, 0.25 s cooldown)
                          LookUpdate(Vector3) ~15 Hz ▶  • battery −10 %/s filming, +3 %/s after 1.5 s lowered
                          (unreliable, while filming)   • WalkSpeed 9 / 16 / 23 + anti-speed rubber-band
                                                        • look: unit vector, ≤40/s, ≤75° from body yaw, ≤0.4 s old
 RealityRenderer  ◀── Player attributes ──────────────  ShutterCamcorder / ShutterBattery / ShutterSprinting
 CamcorderHud          (replicated, server-written)
 WatcherFX        ◀── Watcher model attributes ───────  WatcherService (20 Hz think, Heartbeat movement)
                       WatcherState / WatcherFrozen       • observed = isFilming ∧ in 34° cone ∧ ≤160 studs
                  ◀── WatcherFeedback("Caught") ──────      ∧ server raycast from SERVER head position
 ProximityPrompt ── Triggered (engine) ─────────────▶ InteractionService
                                                        • re-checks filming, distance, view angle, LOS
```

How the networking stays safe:

- **The client only sends requests.** Raising the camcorder, sprinting, battery, speed and Watcher observation are all decided on the server. The client draws the UI from Player attributes that only the server can write. Changes a client makes to attributes are not replicated.
- **Look direction** is the only input a client has to send, because the server can't see where a camera points. It is limited so that it can't be abused:
  - The server only accepts a direction (a unit vector), never a position. The view origin is always the server's own copy of the head position.
  - Packets are rate-limited (40/s).
  - While filming, the camera is forced into first person. A look direction more than 75° from where the replicated body faces is dropped.
  - A direction older than 0.4 s is ignored. A client that stops sending can't keep the Watcher frozen.
  - It only matters while the server agrees the camcorder is up, which drains battery.
- **Hiding is cosmetic; gameplay is validated.** An exploiter could stop hiding `CameraOnly` parts on their own screen. But using a `CameraOnly` prompt (doors, pickups) is re-checked on the server: the camcorder must be filming, the player must be in range, the camera must point at the object, and there must be a clear line of sight. Otherwise the trigger is ignored.
- **The Watcher has no physics owner.** Every part is anchored, and the server moves the model with `PivotTo`. Clients cannot fling it, network-own it or teleport it. When it is frozen, it does not move at all.
- **Speed:** clients simulate their own character, so a client could rewrite its own `WalkSpeed`. The server samples position every 0.5 s. After 3 samples in a row that are faster than the server-allowed speed (×1.6 + 4 studs of slack for jitter), the server moves the player back to their last valid position.

## PART 2: Studio hierarchy

```
ReplicatedStorage
└── Shutter                       Folder
    ├── Config                    ModuleScript   (src/shared/Config.luau)
    ├── Net                       ModuleScript   (src/shared/Net.luau)
    └── Remotes                   Folder
        ├── CamcorderToggle       RemoteEvent            client → server (wantRaised: boolean)
        ├── SprintState           RemoteEvent            client → server (wantSprint: boolean)
        ├── LookUpdate            UnreliableRemoteEvent  client → server (lookDirection: Vector3)
        └── WatcherFeedback       RemoteEvent            server → client (kind: "Caught", watcher: Model)

ServerScriptService
└── Shutter                       Folder
    ├── Main                      Script         (src/server/Main.server.luau)   ← only server entry point
    ├── CamcorderService          ModuleScript   (src/server/CamcorderService.luau)
    ├── InteractionService        ModuleScript   (src/server/InteractionService.luau)
    ├── WatcherService            ModuleScript   (src/server/WatcherService.luau)
    ├── WatcherRig                ModuleScript   (src/server/WatcherRig.luau)
    └── DemoLevel                 ModuleScript   (src/server/DemoLevel.luau)

StarterPlayer
└── StarterPlayerScripts
    └── Shutter                   Folder
        ├── ShutterClient         LocalScript    (src/client/ShutterClient.client.luau) ← only client entry point
        ├── CamcorderController   ModuleScript   (src/client/CamcorderController.luau)
        ├── RealityRenderer       ModuleScript   (src/client/RealityRenderer.luau)
        ├── CamcorderHud          ModuleScript   (src/client/CamcorderHud.luau)
        └── WatcherFX             ModuleScript   (src/client/WatcherFX.luau)

Workspace (yours to build; examples are created by DemoLevel)
├── any Part/Model tagged  CameraOnly      only visible through the camcorder
├── any Part/Model tagged  NakedEyeOnly    only visible without it
├── Model tagged  ShutterDoor              hidden door (see Part 4)
├── Part/Model tagged  ShutterPickup       + CameraOnly, with a ProximityPrompt inside
├── Part tagged  WatcherSpawn              optional Watcher spawn/respawn points
└── Model tagged  ShutterEntity            optional custom Watcher (else one is built for you)
```

`Net` creates any missing remote at server start, so a hand-built place still works if you forget a remote.

## PART 3: Full implementation code

Every script is complete and ready to paste. Each file's header comment explains what it does.

| Path in Studio | Type | File |
|---|---|---|
| ReplicatedStorage › Shutter › Config | ModuleScript | [`src/shared/Config.luau`](src/shared/Config.luau) |
| ReplicatedStorage › Shutter › Net | ModuleScript | [`src/shared/Net.luau`](src/shared/Net.luau) |
| ServerScriptService › Shutter › Main | Script | [`src/server/Main.server.luau`](src/server/Main.server.luau) |
| ServerScriptService › Shutter › CamcorderService | ModuleScript | [`src/server/CamcorderService.luau`](src/server/CamcorderService.luau) |
| ServerScriptService › Shutter › InteractionService | ModuleScript | [`src/server/InteractionService.luau`](src/server/InteractionService.luau) |
| ServerScriptService › Shutter › WatcherService | ModuleScript | [`src/server/WatcherService.luau`](src/server/WatcherService.luau) |
| ServerScriptService › Shutter › WatcherRig | ModuleScript | [`src/server/WatcherRig.luau`](src/server/WatcherRig.luau) |
| ServerScriptService › Shutter › DemoLevel | ModuleScript | [`src/server/DemoLevel.luau`](src/server/DemoLevel.luau) |
| StarterPlayerScripts › Shutter › ShutterClient | LocalScript | [`src/client/ShutterClient.client.luau`](src/client/ShutterClient.client.luau) |
| StarterPlayerScripts › Shutter › CamcorderController | ModuleScript | [`src/client/CamcorderController.luau`](src/client/CamcorderController.luau) |
| StarterPlayerScripts › Shutter › RealityRenderer | ModuleScript | [`src/client/RealityRenderer.luau`](src/client/RealityRenderer.luau) |
| StarterPlayerScripts › Shutter › CamcorderHud | ModuleScript | [`src/client/CamcorderHud.luau`](src/client/CamcorderHud.luau) |
| StarterPlayerScripts › Shutter › WatcherFX | ModuleScript | [`src/client/WatcherFX.luau`](src/client/WatcherFX.luau) |

All files use `--!strict`, `task.*`, and CollectionService tags. None use `wait`/`spawn`/`delay`, `_G`, or hard-coded instance paths into Workspace.

## PART 4: Installation instructions

Pick **one** option.

### Option A: Open the ready-made place
`File → Open from File… → build/TheShutter.rbxlx`. Everything is already in place.

### Option B: Add to an existing place (model files)
1. In Studio, open the **Model** tab and use **Insert from File** three times, for these files in `build/`:
   - `TheShutter_ReplicatedStorage.rbxmx`: drag the inserted **Shutter** folder into **ReplicatedStorage**
   - `TheShutter_ServerScriptService.rbxmx`: drag **Shutter** into **ServerScriptService**
   - `TheShutter_StarterPlayerScripts.rbxmx`: drag **Shutter** into **StarterPlayer › StarterPlayerScripts**
2. Each folder must be named exactly `Shutter`. The scripts find each other through these names.

### Option C: Rojo
```bash
cd shutter && rojo serve default.project.json
```

### Option D: By hand
Create the tree in Part 2. Give each object exactly the name shown. Paste each file's contents into it.

### Tagging your own level
Use **View → Tag Editor**, or run `game:GetService("CollectionService"):AddTag(obj, "CameraOnly")` in the command bar.

| You want | Do this |
|---|---|
| Something only the camcorder sees (writing, footprints, anomaly) | Tag the Part or Model **`CameraOnly`**. Decals, lights, particles, GUIs, prompts and sounds inside it are hidden too |
| Something that disappears when filmed (the "pristine" lie) | Tag it **`NakedEyeOnly`** |
| **Hidden door** | 1. Create a Model and tag it **`ShutterDoor`**. 2. Inside it, add a wall Part tagged **`NakedEyeOnly`** (`CanCollide = true`, matching your wall). This is what blocks the way. 3. Add a door Part tagged **`CameraOnly`** (`CanCollide = false`) with a **ProximityPrompt** inside. When the prompt is used, the server turns off collision on every part and fades them out for all players |
| **Pickup** | Tag a Part **`CameraOnly`** + **`ShutterPickup`** and add a **ProximityPrompt**. Add attribute `PickupKind` = `"Clue"` or `"Battery"`. Optional attribute `Amount` (number) |
| Watcher spawn points | Add any Parts tagged **`WatcherSpawn`**. Set `Transparency = 1`, `CanCollide = false`. After a catch, the Watcher respawns at the one farthest from players |
| Custom Watcher model | Tag a Model **`ShutterEntity`** and set its PrimaryPart. The server anchors it, makes it non-collidable, adds `CameraOnly`, and removes any Humanoid. Its feet are the bottom of its bounding box |
| Turn off the demo map | `Config.DEMO_LEVEL = false`. The demo also skips itself if your place already has `CameraOnly` objects |

Recommended settings:
- **Workspace › PathfindingService:** the default settings are fine. Make doorways at least 5 studs wide (`AGENT_RADIUS = 2`).
- Set `Config.FX.*_SOUND` to `rbxassetid://` ids to add camcorder, static and jumpscare audio.

## PART 5: Studio testing steps

### Single player (Play / F5)
1. **Output should show:**
   `[Shutter] Demo level built…` then `[Shutter] Server systems online…`
2. **Naked eye:** The room looks normal. The wall section ahead and to the right is plain wall. There is no writing, no footprints and no Watcher. Walk (16), then hold **Shift** (23).
3. **Press F:** You switch to first person and the FOV narrows. You see the REC dot, timecode, scanlines and green-tinted colour. Movement slows to 9. The battery drops about 10 % per second.
4. **Dual reality:** Red footprints lead to a red door where the wall section was. The message "IT ONLY MOVES WHEN YOU LOOK AWAY" appears on the left wall. The Watcher is visible far ahead.
5. **Battery:** Keep filming until it reaches 0. The camcorder lowers itself. Pressing F again does nothing until the battery is back above 5 %. Recharge starts 1.5 s after lowering and runs at 3 %/s.
6. **Look to survive:** Film the Watcher. It stops dead and **[ SUBJECT HELD ]** flashes. Turn away or lower the camcorder and it moves again: it stalks at 11 and hunts at 18 within 45 studs. Sprinting (23) outruns it.
7. **Caught:** Let it reach you. The screen flashes white, then black with "YOU LOOKED AWAY", and you die. After about 3.6 s it respawns at the WatcherSpawn.
8. **Hidden door:** Film the red door and hold **E**. The door and fake wall fade out, and the closet is open. Film the two glowing cubes and take them. The Clue raises `ShutterClues`. The Battery adds 40 %.
9. **Exploit checks:** These need the client view. In the top bar, under **Test**, switch the **Current: Client** toggle to client. Then run each line in the command bar:
   - `game.Players.LocalPlayer.Character.Humanoid.WalkSpeed = 80` Within about 1.5 s the server pulls you back to your last valid position, and keeps doing so while you move too fast.
   - `game.Players.LocalPlayer:SetAttribute("ShutterBattery", 100)` Only your own HUD changes. The server's battery doesn't change, and the attribute snaps back the next time the server's value changes.
   - Lower the camcorder. Then run `game.ReplicatedStorage.Shutter.Remotes.LookUpdate:FireServer(Vector3.new(0,0,-1))` The Watcher keeps moving, because looks are ignored unless the server says you are filming.

### Local Server (Test → Clients and Servers → 2 players)
1. In **Player1**, film the Watcher. It freezes for **both** players, because observation is global. **Player2** cannot see it without filming.
2. With **Player2**, lead the Watcher away while Player1 films a wall. The Watcher chases Player2 (the nearest player) and is unaffected by Player1.
3. In the server view, select `TheWatcher` in Workspace and check its attributes. `WatcherState` cycles through Idle → Stalking → Hunting → Frozen → Cooldown.
4. Select a Player and check its attributes. Server-side `ShutterBattery` / `ShutterCamcorder` match each client's HUD.

### Reading errors
| Message | Meaning / fix |
|---|---|
| `[Shutter] ReplicatedStorage.Shutter.Remotes is missing` | The server script isn't running. Check that `ServerScriptService › Shutter › Main` exists and is enabled |
| `Infinite yield possible on 'ReplicatedStorage:WaitForChild("Shutter")'` | The shared folder is missing or misnamed. It must be exactly `Shutter` |
| `Watcher … has no parts; ignoring it` | A `ShutterEntity` model is empty |
| `… contains a Humanoid; it is not needed and was removed` | This is expected for custom models. Anchored parts and PivotTo replace the Humanoid |
| The Watcher stands still while Stalking | No path was found. Check doorway widths, `AGENT_RADIUS` / `AGENT_HEIGHT` and the floor under its spawn. Use **File → Studio Settings → Studio → Show Navigation Mesh** to see the navmesh |
| Hidden things show to the naked eye | The tag is on the wrong instance, or a script is setting `LocalTransparencyModifier` on them |
| Prompt appears but does nothing | The server rejected the trigger. Check that you are filming, within `MaxActivationDistance + 2`, looking at it, and that nothing solid is in between |

## PART 6: Integration checklist (Camcorder & Battery framework)

`CamcorderService` **is** the core framework. Other server systems should read it, not duplicate it.

**Server API (`require(ServerScriptService.Shutter.CamcorderService)`)**

| Function | Use |
|---|---|
| `isFilming(player) → boolean` | Camcorder up, battery > 0, alive. Use this to gate anything that is "camera only" |
| `getLook(player) → (origin: Vector3?, dir: Vector3?)` | Server head position + fresh validated look. Returns nil if not filming or the data is stale |
| `getBattery(player) → number` / `addBattery(player, n)` | Battery pickups, generators and penalties |
| `forceLower(player, reason?)` | Cutscenes, being caught, EMP anomalies |
| `allowTeleport(player, seconds?)` | **Call before any server teleport** so the anti-speed check doesn't rubber-band the player |
| `onCamcorderChanged(fn(player, raised, reason))` | Reason is one of `"request"`, `"battery"`, `"died"`, `"respawn"`, `"caught"`, `"forced"`. Returns an unsubscribe function |

Other server APIs: `WatcherService.getObservers(model)`, `getState(model)`, `getWatchers()`, `onObserved(fn)`, and `InteractionService.onInteracted(fn(player, target, prompt))`.

**Checklist**
- [ ] Nothing else sets `Humanoid.WalkSpeed`. Speed is calculated in `CamcorderService.allowedSpeed()`. For new modifiers (injury, crouch), add them there so the anti-speed check knows about them.
  ⚠ The repo's Poolrooms `WaterMovement` LocalScript rewrites WalkSpeed on the client. Don't combine it with THE SHUTTER unchanged, or the anti-speed check will fight it.
- [ ] UI reads the Player attributes `ShutterBattery`, `ShutterCamcorder`, `ShutterSprinting` and `ShutterClues`. UI never writes them.
- [ ] New "visible only on tape" content uses the **`CameraOnly`** tag, not custom scripts. Any gameplay action it unlocks is validated with `isFilming` + `getLook` (copy `InteractionService.validate`).
- [ ] Server code that changes `Enabled`/`Transparency` on CameraOnly effects is fine, because RealityRenderer adopts the server's value. Remove used prompts with `:Destroy()`.
- [ ] Other entities that use "freeze when watched" can reuse the `observersOf` pattern from `WatcherService` (view cone + server raycast).
- [ ] Tuning lives only in `ReplicatedStorage.Shutter.Config`: speeds 16/23/9, battery 10 %/s drain, 3 %/s recharge, 1.5 s delay.
- [ ] To rebuild the downloadable files after editing `src/`, run `python3 shutter/tools/build_studio_files.py`.
