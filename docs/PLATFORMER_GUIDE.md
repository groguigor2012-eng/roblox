# Inkwood Platformer Framework

A server-secure framework for a Roblox 3D platformer and collectathon. It has three parts:

1. **Movement**: double jump with a spin and short float, directional dash (`E`), ground pound (`LeftShift`), wall jump and coyote time, each with local effects. A right-click attack animation sits alongside them.
2. **Progression**: persistent Shards and Power Orbs, session-locked DataStore saves, leaderstats, and one collectible system that serves every item tagged in CollectionService.
3. **Health UI**: three hearts drawn from `Humanoid.Health`, plus a red damage flash and a short camera shake.

It lives next to the Poolrooms game in this repository as a **separate Rojo project**
(`platformer.project.json`). Poolrooms uses `CameraMode = LockFirstPerson` and has no movement,
data or UI systems, so a third-person platformer can't share its place. Neither project changes
the other.

```sh
rojo serve platformer.project.json              # live sync into an empty place
rojo build platformer.project.json -o Platformer.rbxl
```

---

## 1. Architecture

```
            ┌────────────── ReplicatedStorage.Shared ──────────────┐
            │ Config/* (tunables)  Types  Math/*  Utilities/*      │
            │ Remotes/ (created by the server at startup)          │
            └───────────────▲───────────────────────▲──────────────┘
                            │                       │
 ServerScriptService.Server │                       │ StarterPlayerScripts.Client
 ┌──────────────────────────┴───┐       ┌───────────┴───────────────────────┐
 │ Bootstrap.server             │       │ Bootstrap.client                  │
 │  RemoteRegistry              │       │  CharacterLifecycle               │
 │  CharacterService            │       │  CollectibleVisualController ─┐   │
 │  PlayerDataService ◄─┐       │       │  MovementController ──────────┼─► │ remotes
 │  ProgressionService ─┘       │       │  HeartUIController            │   │
 │  DestructibleService         │       │  FeedbackController           │   │
 │  CollectibleService          │◄──────┼───────────────────────────────┘   │
 │  MovementValidationService   │       │  Utilities/Effects (local VFX)    │
 │  DemoCourse (optional)       │       └───────────────────────────────────┘
 └──────────────────────────────┘
```

* **No framework dependency.** The project had no Knit or other framework, so it uses plain
  services and controllers, with one bootstrap on each side. Services `require` each other
  directly. The dependency graph has no cycles:
  Progression → PlayerData; Collectible → Character, PlayerData, Progression;
  MovementValidation → Character, Destructible. Each bootstrap starts its modules once, in a
  documented order. Every `Start` asserts it has not run before.
* **Ownership.** The server owns data, rewards, world destruction and validation. The client owns
  input, physics for its own character (Roblox gives clients network ownership of their
  characters), cosmetics, UI and the camera.
* **Startup failure policy.** If a server step fails before the services are all up, the server
  logs the stack trace and kicks current and future players with an explanation. It never runs
  half-wired. A failed client controller is logged and skipped, so the other controllers keep
  working.

## 2. Files

`*.server.luau` = Script, `*.client.luau` = LocalScript, everything else = ModuleScript.

| Path (Studio) | Responsibility | Depends on |
|---|---|---|
| `ReplicatedStorage/Shared/Config/GameConfig` | Tags, folders, remote contract, health, collision groups, destructible attributes, security, demo course | — |
| `…/Config/MovementConfig` | Every movement number, curve and validation tolerance | — |
| `…/Config/CollectibleConfig` | Collectible attributes, rewards, pickup radii, rate limits, visuals | — |
| `…/Config/HealthUIConfig` | Heart layout and style, flash and shake | — |
| `…/Config/DataConfig` | DataStore name, schema version, retry, session lock, autosave, kick messages | — |
| `…/Shared/Types` | Shared types and every remote payload | — |
| `…/Config/AnimationConfig` | Every custom animation id (attack, spin pose, dash roll), with priority, speed and fade | — |
| `…/Config/CombatConfig` | Right-click attack: input, trigger mode, cooldown, blocked states, fallback punch | — |
| `…/Shared/Math/MovementMath` | Pure maths for curves, directions, wall launch, descent, spin profile and float lift (unit-tested) | MovementConfig |
| `…/Shared/Math/AttackMath` | Pure fallback-punch pose curve and click-versus-drag test (unit-tested) | — |
| `…/Shared/Math/HealthMath` | Pure heart formula (unit-tested) | — |
| `…/Shared/Utilities/ResourceCleanup` | Releases connections, instances, threads and callbacks together | — |
| `…/Shared/Utilities/Logger` | Structured `[Platformer/Scope] Event key=value` logs | GameConfig |
| `…/Shared/Remotes/*` | **Created at runtime** by `RemoteRegistry` | — |
| `ServerScriptService/Server/Bootstrap` (Script) | Ordered startup and failure lockdown | all services |
| `…/Services/CharacterService` | MaxHealth, collision groups, cached alive/root records, spawn/death callbacks | GameConfig |
| `…/Services/PlayerDataService` | Load/save, session lock, autosave, BindToClose, leaderstats, the **only** currency path | ProfileStore, DataSchema |
| `…/Services/ProgressionService` | Trusted reward sources, atomic collectible claims, rollback | PlayerDataService |
| `…/Services/CollectibleService` | Tag registry, attribute validation, pickup remote, Shared respawns | Character, PlayerData, Progression |
| `…/Services/MovementValidationService` | Action rate/cooldown checks, ground-pound registration and impact validation | Character, Destructible |
| `…/Services/DestructibleService` | Breakable registry, server spatial query, hits/respawn | GameConfig |
| `…/Utilities/DataStoreRetry` | Bounded exponential backoff with jitter; non-retryable codes | — |
| `…/Utilities/DataSchema` | Defaults, normalisation, migrations, id validation | Configs, Types |
| `…/Utilities/SessionLock` | Pure lock rules (Free/Owned/Expired/HeldByOther) | — |
| `…/Utilities/ProfileStore` | Atomic `UpdateAsync` acquire, write and release | the three above |
| `…/Utilities/MemoryDataStore` | In-memory store for tests and the Studio-only fallback | — |
| `…/Utilities/RateLimiter` | Per-player token bucket | — |
| `…/Utilities/RemoteRegistry` | Creates and verifies remotes, parenting the folder last | GameConfig |
| `…/Utilities/DemoCourse` | Optional test level (see §4.8) | Configs |
| `StarterPlayer/StarterPlayerScripts/Client/Bootstrap` (LocalScript) | Waits for and verifies remotes, then starts controllers | all controllers |
| `…/Client/Utilities/CharacterLifecycle` | Per-spawn context and cleanup group; spawn/died/despawn fan-out | ResourceCleanup |
| `…/Client/Utilities/Effects` | Trails, bursts, shockwave, debris, pickup ghost, floating text | Configs |
| `…/Client/Utilities/CharacterAnimations` | Loads and plays AnimationConfig entries on the character's Animator; preloads ids and falls back if one fails | Lifecycle |
| `…/Client/Controllers/MovementController` | Input, ability state machine (incl. spin-float), local effects, movement remotes | Lifecycle, Animations, Effects, Feedback |
| `…/Client/Controllers/AttackController` | Right-click/R1/touch attack: Animator track or procedural punch | Lifecycle, Animations, MovementController |
| `…/Client/Controllers/CollectibleVisualController` | Shared spin/bob loop, per-player hiding, pickup requests | Lifecycle, Effects |
| `…/Client/Controllers/HeartUIController` | Builds `PlayerGui.HeartUI`; hearts follow the Humanoid | Lifecycle, HealthMath |
| `…/Client/Controllers/FeedbackController` | Damage flash overlay and trauma-based camera shake | Lifecycle |
| `platformer.project.json` | Rojo tree; turns off the shift-lock option (LeftShift is ground pound) | — |
| `platformer/tests/*` | Lune harness, unit tests, contract checks | — |

**Deviations from the requested layout:**

* `ResourceCleanup` is in `Shared/Utilities`, not `Server/Utilities`, because client controllers need it too.
* The pure maths lives in `Shared/Math`.
* `HeartUI` is built in code into `PlayerGui`, not placed in `StarterGui`, so it needs no assets.
* Eight server modules are additions to the requested list: `CharacterService`, `DataSchema`,
  `SessionLock`, `ProfileStore`, `MemoryDataStore`, `RateLimiter`, `RemoteRegistry` and
  `DemoCourse`. They keep the DataStore logic testable and the services small.

## 3. Remote contract

All six are `RemoteEvent`s. `RemoteRegistry` creates them under `ReplicatedStorage.Shared.Remotes`
and errors if a same-named instance has the wrong class. The client waits up to 30 s and refuses
to start its networked controllers if any remote is missing.

| Remote | Direction | Payload | Server checks |
|---|---|---|---|
| `CollectRequest` | C→S | `(target: Instance)` | Token bucket (15, +10/s); exactly one argument; target is a registered collectible inside `Workspace.Collectibles`; data Ready; character alive; server-measured distance ≤ 10 + half the item's size; atomic claim (no yield) |
| `CollectResult` | S→C (requester only) | `{Success, Instance?, CollectibleId?, CurrencyType?, Amount?, NewTotal?, Reason?}` | Built only by the server |
| `CollectionState` | S→C | `{CollectedIds: {string}}` | Sent once the data is Ready |
| `MovementAction` | C→S | `(action: "DoubleJump"\|"Dash"\|"WallJump")` or `("GroundPoundStart", poundId: integer)` | Token bucket (12, +8/s); payload shape; ability enabled; alive; per-action minimum interval (cooldown − 0.12 s); pound id strictly increasing; no other pound active; **server raycast** shows the root is high enough above ground |
| `GroundPoundImpact` | C→S | `(poundId: integer, impactPosition: Vector3)` | Token bucket; finite vector; must match the registered pound; **one impact per pound**; within the pound's lifetime; within 14 + 140·ping studs of the server's root; horizontal drift ≤ 10 + 40·ping; not above the start; **server raycast** finds ground. The server then picks the centre and the parts |
| `ImpactEffect` | S→C (source + players within 300 studs) | `{Position, Radius, SourceUserId, Broken: {CFrame, Size, Color, Material}[]}` | Every value is server-generated |

Rule violations add to a per-player score: one point per violation, decaying by one every 30 s.
The score is logged at multiples of 5. The server kicks only if `ViolationKickThreshold > 0`.
It is 0 by default, because movement is client-simulated and laggy players shouldn't be kicked
for false positives. Normal lag (late packets, a pound that starts too low on the server's view)
is rejected quietly without counting as a violation.

## 4. Studio setup

### 4.1 Build the place
1. `rojo build platformer.project.json -o Platformer.rbxl` and open it. Alternatively, run
   `rojo serve platformer.project.json` and connect with the Rojo plugin from an empty Baseplate.
2. Without Rojo, recreate the tree in §2: Folders for directories, and the Script, LocalScript or
   ModuleScript type the suffix indicates. Name each instance after its file without the
   extension, so `Bootstrap.server.luau` becomes a Script named `Bootstrap`.
3. Set **StarterPlayer.EnableMouseLockOption = false**. Rojo already does this. Shift-lock also
   uses LeftShift; the ground pound only sinks the key when it actually fires, but turning
   shift-lock off avoids confusion.

### 4.2 Folders
The project creates `Workspace.Collectibles` and `Workspace.Destructibles`. If they are missing,
the services create them. Collectibles **must** be inside `Workspace.Collectibles`, nested at any
depth. Breakables can be anywhere; the tag is what counts.

### 4.3 Tags

| Tag | Applies to | Effect |
|---|---|---|
| `Collectible` | `BasePart` or `Model` under `Workspace.Collectibles` | Registered by `CollectibleService` (server) and `CollectibleVisualController` (client). The server forces it to Anchored, CanCollide=false and CanTouch=false. **Do not put scripts inside.** |
| `GroundPoundBreakable` | `BasePart` only (other classes get a warning and are ignored) | Can be broken by validated ground-pound impacts |

Add tags with the **Tag Editor** (View → Tags) or `part:AddTag("Collectible")`.

### 4.4 Collectible attributes

| Attribute | Type | Required | Default | Notes |
|---|---|---|---|---|
| `CollectibleId` | string | for persistence | — | Unique and stable forever. `^[%w_%-%.:]+$`, ≤ 64 chars. Duplicates are rejected with a warning. Without one, the item is collectible once per player **per server session** and never saved (a warning names it) |
| `CollectibleType` | string | **yes** | — | `"Shards"` or `"PowerOrbs"` |
| `RewardAmount` | number | no | 1 | Integer 1–1000; read only on the server |
| `Persistent` | boolean | no | `true` | `false`: per-player, but resets every server session |
| `CollectMode` | string | no | `"PerPlayer"` | `"Shared"`: the first player to touch it collects it for everyone |
| `RespawnSeconds` | number | no | 0 | Shared only; 0 = never comes back |
| `Available` | boolean | — | — | **Written by the server** for Shared items; don't set it by hand |

For `StreamingEnabled` places, set each collectible Model's `ModelStreamingMode = Atomic` so it
streams in as one piece. The client copes with partial models, but atomic is cleaner.

### 4.5 Breakable attributes (all optional)

| Attribute | Type | Default | Effect |
|---|---|---|---|
| `BreakOnGroundPound` | boolean | `true` | `false` makes a tagged part immune |
| `GroundPoundMinPower` | number | 0 | Minimum **server-measured** fall distance in studs |
| `BreakHits` | integer | 1 | Number of qualifying pounds needed to break it |
| `RespawnSeconds` | number | 0 | Restore the part after this long; 0 = destroyed for good |

### 4.6 DataStore
* The store is named `PlatformerPlayerData` (`DataConfig.DataStoreName`). Each player has one key,
  `Player_<UserId>`.
* To test real saves in Studio, publish the place and enable **Game Settings → Security → Enable
  Studio Access to API Services**. Use a separate test experience or a different
  `DataStoreName`, so Studio sessions never write to live data.
* With API access off, Studio falls back to an in-memory store and logs `UsingMemoryStore`.
  Progress then resets when you stop. Live servers never fall back; they refuse to load instead.
* After changing the PlayerData layout, bump `DataConfig.SchemaVersion` and add
  `DataSchema.Migrations[old]`.

### 4.7 Custom animations (optional; you supply them)
**No animation asset ships with this project.** Every id in `Shared/Config/AnimationConfig` is
empty, and each has a working fallback:

| Entry | Plays | If empty or unloadable |
|---|---|---|
| `AnimationConfig.Attack` | right-click attack (wind-up, hit, recovery) | procedural right-arm punch, **visible only to you** (see §7) |
| `AnimationConfig.DoubleJumpSpin` | pose held during the spin (looped) | the spin still happens; the normal fall animation plays |
| `AnimationConfig.DashRoll` | dash roll (moved here from `MovementConfig.Dash.RollAnimationId`) | dash with trail and dust only |

To add one:
1. Make it in the **Animation Editor** (Avatar tab), using a rig of the same type your game spawns
   (R15 by default). Use an animation you created or have permission to use.
2. Key **only the upper body** for the attack, so the legs keep running underneath it. Add a
   wind-up, the hit and a recovery. Set the attack and roll to not loop, and the spin pose to loop.
3. **Publish to Roblox** under the **same owner as the experience** (your account, or the group
   that owns the game). Roblox won't load animations owned by someone else in your game.
4. Copy the asset id into the entry: `AnimationId = "rbxassetid://1234567890"`.
5. If the id fails to load, the output shows `AnimationUnavailable` once and the fallback is
   used for the rest of the session.

An R15 animation does not play on R6 characters, and an R6 one does not play on R15.

### 4.8 Demo course
`GameConfig.DemoCourse.Mode` is `"Always"`, so a blank place is playable straight away. Switch it
to `"StudioOnly"` or `"Off"` once you build real levels. The course contains about 190 shards: a
ring, steps, a 120-item spiral and a shaft. It also has:
* a wall-jump shaft with a Power Orb on top
* a vault whose glass roof tiles break on a ground pound and respawn after 30 s. The purple tile
  needs a fall of at least 12 studs; the grey one needs two pounds. Power Orbs sit inside.
* a Shared shard that respawns after 10 s, and a shard with `Persistent = false`
* a red damage pad (−20 HP) and a green heal pad (+25 HP)

### 4.9 Multiplayer test
**Test → Clients and Servers → 2 players → Start.** Check the per-player hiding, the replicated
impact effects and the session behaviour (§6).

### 4.10 UI
`HeartUI` sits at DisplayOrder 5 in the top-left corner, below Roblox's top-bar inset
(`IgnoreGuiInset = false`), so the default UI never covers it. The default health bar is hidden
only after `HeartUI` builds successfully.

## 5. Security, persistence and performance

**Server-authoritative:** currency, collected ids, which items exist and what they're worth,
pickup distance, Shared availability, which parts break, the impact centre, MaxHealth and all
saved data.

**Client-simulated:** all character motion: double jump, dash, wall jump, pound descent and
recovery. Clients own their characters' physics, so the server can't veto motion. It does record
every reported ability, enforce per-action spacing and rate limits, and keep a violation score.
**A ground pound only affects the world** if the server registered its start and the impact
passes its own timing, distance, drift, height and ground checks. A forged `GroundPoundImpact`
without a registered start does nothing. A replayed impact does nothing, because each pound is
processed once. A client-supplied list of parts is impossible, because the payload has no such
field.

**No reward duplication:**
* The client sends only an `Instance`. The server finds it in its own registry and reads the type
  and amount there.
* `ProgressionService.ClaimCollectible` checks and records the id, then grants the reward, with
  no yield in between. Luau runs it to completion, so two concurrent requests can't both pass the
  check.
* If the grant still fails, the claim is rolled back.
* Shared items flip `Available` in the same yield-free block.

**Persistent collectibles:** the stable ids are stored in a set in
`PlayerData.CollectedCollectibles`. On join, the server sends them through `CollectionState`.
The client hides those items locally whenever they exist or stream in, so they stay hidden after
respawns and rejoins. Other players still see them. An `AlreadyCollected` reply also hides the
item, which covers any race.

**Session locks and saves:**
* `Acquire`, `Write` and `Release` all run inside `UpdateAsync`, so the check and the write happen
  together.
* A lock owned by another live server blocks the load. The server retries 5 times, 3 s apart,
  then kicks with "still open on another server".
* A lock that hasn't been refreshed for 300 s counts as a crashed server and may be taken. This
  is logged. The stale server's next write then sees `LostLock`, stops saving and kicks its
  player.
* Autosave runs every 60 s. It writes dirty profiles, and refreshes the lock of clean profiles
  older than 120 s.
* Saves for the same player are serialised: a save requested mid-save causes exactly one more
  write afterwards.
* Retries are bounded: 5 attempts with backoff `min(8, 0.5·2^(n−1))·(1+0.3·r)`, waiting for
  request budget. Errors with non-retryable codes (101–106, 401–406, Studio access) fail at once.
* A failed load **never** substitutes defaults. The player is kicked and the stored data stays
  untouched.
* `BindToClose` releases every session in parallel and waits up to 25 s.
* A player who leaves mid-load still has the lock released. A fast rejoin to the same server
  waits for the previous profile to finish releasing.

**Cleanup:**
* Everything tied to a character goes into its `CharacterLifecycle` cleanup group, which is
  destroyed on despawn: connections, the `LinearVelocity` mover, the `AngularVelocity` spinner,
  the `VectorForce` float, attachments, trails, emitters and every loaded animation track.
* Abilities end through one `endAbility` path. It disconnects the per-frame step, disables all
  three constraints, restores `Humanoid.AutoRotate` if the spin turned it off, and stops the
  ability's animation. Landing, death, despawn, and starting any other ability all go through it.
* Delayed callbacks check an ability token, so a stale timer can't end a newer ability.
* Collectible watchers are destroyed when the tag is removed or the item streams out.
* Effects are removed by a tween completion, with `Debris` as a backstop. Burst emitters are
  pooled.
* Camera shake binds a render step only while trauma is above 0.

**Per-frame work, and why:**
* Dash and pound need per-physics-step velocity updates and a landing probe. They use one
  `PreSimulation` connection that exists only while the ability runs.
* Collectible animation needs per-frame CFrames. One `PreRender` loop with one `BulkMoveTo`
  covers every streamed-in item within 220 studs of the camera, and the proximity check inside
  it runs at 10 Hz.
* Camera shake binds a render step only while active.
* Grounding, health, collectible registration, Shared availability and damage are all
  event-driven.

**Engine limitations:**
* Client-owned character physics means motion can't be fully authoritative without a
  server-side character controller.
* Roblox queues remote events until a handler connects. `CollectionState` relies on that, with
  the `AlreadyCollected` reply as a fallback.
* Lock expiry depends on `os.time()` agreeing roughly across servers. Negative ages from clock
  skew are treated as live locks.

## 6. Tests and acceptance checklist

### 6.1 Automated (run in this repository)

| Check | Command | Result |
|---|---|---|
| Strict type check against the Roblox API, both Luau solvers | `luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json --definitions=@roblox=globalTypes.d.luau $(find platformer/src -name '*.luau')` (add `--no-flags-enabled` for the old solver) | 0 errors, 0 lint warnings |
| Rojo build | `rojo build platformer.project.json -o Platformer.rbxl` | builds |
| Unit tests (Lune) | `platformer/tests/run.sh` | 62 passed |
| Contract checks (Lune) | same script | 10 passed |

The unit tests cover:
* curve endpoints, monotonicity and clamping; dash speed endpoints and midpoints; descent cap
* dash direction fallbacks: zero input, pitch ignored, straight up
* wall-normal acceptance and floor rejection; the wall launch follows the normal at the configured
  speed and ratio
* heart boundaries at exactly 200/3 and 100/3; NaN, negative, zero or infinite MaxHealth;
  MaxHealth changes
* schema: defaults, repairs that keep valid fields, unknown fields dropped, array ids, the v0
  migration, future-schema refusal, corrupt values, the id cap
* every session-lock state
* backoff, retry, non-retryable codes and bounds
* ProfileStore against an in-memory DataStore:
  * a second server is blocked
  * a stale server can't save after an expiry takeover
  * release frees the lock
  * a lost release response isn't reported as a failure
  * exhausted retries and failed loads leave data intact
  * legacy records migrate
  * future-schema records are left alone
* the rate limiter, cleanup order and error reporting, and config invariants

The contract checks confirm that every `XConfig.path` in code exists and every config key is
used. They also confirm that each remote is declared in `Types`, documented in `GameConfig`, and
fired and handled in the right direction.

### 6.2 Manual, in Studio. Not run here: this environment has no Roblox client

**Movement**
- [ ] First jump is ordinary. Exactly one air jump; holding Space does not repeat it; landing restores it.
- [ ] Walking off a ledge and jumping within 0.12 s is a normal jump, and the air jump remains.
- [ ] The trail and burst show on the air jump, and nothing is left under `Workspace.LocalEffects` afterwards.
- [ ] `E` dashes along the movement input. With no input, it dashes in the facing direction, never upward. The speed fades fast to slow. The 0.75 s cooldown holds. One air dash per airtime.
- [ ] Jumping mid-dash cancels it. Dying mid-dash leaves no `PlatformerMover` enabled after respawn.
- [ ] `LeftShift` works only in the air, at least 6 studs up. Brief hang, then a straight drop. Shockwave and camera shake on landing. Each pound breaks the vault roof tile below it (repeatable while it respawns); the purple tile needs a ≥ 12-stud drop, the grey one two pounds. Untagged parts and players are never affected.
- [ ] Wall jump in the shaft pushes away from the wall and upward. The same wall can't be reused within 0.6 s. A floor below never counts as a wall. A wall jump restores the air jump.
- [ ] With 2 clients, the other player sees your shockwave and debris.

**Double-jump spin and float**
- [ ] The air jump goes slightly higher than before, spins about one full turn (smooth start and stop) and hangs near the top, then falls normally. Holding nothing never keeps you up.
- [ ] Steering with WASD works throughout the spin and float.
- [ ] The trail draws the whole spin, and the burst plays.
- [ ] Mid-spin, `E` dashes, `LeftShift` pounds, and jumping next to a wall wall-jumps. Each stops the spin immediately, and the character faces the movement direction again afterwards.
- [ ] Landing mid-spin stops it at once. After landing, walking turns the character normally (AutoRotate restored).
- [ ] Die mid-spin (damage pad), then respawn: no spinning, and in the Explorer `PlatformerSpin` and `PlatformerFloat` under `HumanoidRootPart` are disabled.
- [ ] With 2 clients, the other player sees you spin. Only your own trail is local.

**Right-click attack**
- [ ] A quick right-click plays the punch: wind-up, hit, recovery. Holding right-click and dragging turns the camera **without** attacking.
- [ ] Spam-clicking attacks at most once per 0.45 s, and the punch never restarts mid-swing.
- [ ] Attacking while running, jumping and spinning works, and the legs keep their animation. Nothing happens during a ground pound or its landing.
- [ ] Right-clicking on a button or in the chat box doesn't attack.
- [ ] Gamepad R1 and the on-screen "Hit" touch button attack.
- [ ] Die mid-punch, then respawn: the arm is in its normal pose. Test with an R6 avatar too (Game Settings → Avatar → R6): the arm punches, with no elbow or waist motion.
- [ ] With a custom `AnimationConfig.Attack` id: it plays instead of the fallback, and the other client sees it. With a bogus id: one `AnimationUnavailable` warning, then the fallback.

**Progression**
- [ ] A new player has `Shards 0 / PowerOrbs 0`. Shards and orbs update the correct leaderstat.
- [ ] Re-join (with API access on): totals restored, collected items stay hidden, and **the other client still sees them**.
- [ ] The Shared shard disappears for everyone and returns after 10 s. The `Persistent=false` shard returns in a new server.
- [ ] Forged requests from the command bar, e.g. `CollectRequest:FireServer(workspace.Baseplate)`, a distant item, `GroundPoundImpact:FireServer(999, Vector3.zero)` or repeated `FireServer` calls, grant and break nothing. Turn on `GameConfig.Debug.VerboseLogging` to see the reasons.
- [ ] Two servers: join A, then join B with the same account. B waits and retries; once A releases, B loads A's latest save.
- [ ] Stop the server with players in it: `BindToClose` saves them, and no `ShutdownSaveTimeout` appears.

**Health UI**
- [ ] Three hearts at full health. With the demo damage pad (−20 per touch), health 80 → 60 → 40 → 20 → 0 shows 3 → 2 → 2 → 1 → 0 hearts (the boundaries are 66.7 and 33.3). Healing refills the hearts. Each hit gives one short flash and a small shake; healing gives neither.
- [ ] After 5 respawns, still exactly one `HeartUI` and one `PlatformerDamageFlash` ScreenGui, and hearts follow the new Humanoid.
- [ ] The UI stays readable between 1280×720 and 3840×2160 and on phone emulation (UIScale is clamped between 0.75 and 1.35).

**Performance**
- [ ] The MicroProfiler shows one `PreRender` collectible loop. The Developer Console's network stats show no replication traffic from spinning items.

## 7. Double-jump spin/float and right-click attack

### How they fit in
* **Spin-float** is a new ability (`"SpinFloat"`, state `"SpinFloating"`) in
  `MovementController`'s existing state machine. Every double jump starts it; wall jumps don't.
  * It can be interrupted by dash, ground pound and wall jump, through the same `CAN_START`
    table as the other abilities.
  * Like wall jumps, it is "air-only", so landing ends it.
  * Each character gets two extra constraints at spawn, both off by default: an
    `AngularVelocity` for the spin and a `VectorForce` for the float.
  * Steering stays with the Humanoid. The spin only constrains rotation and the float only adds
    an upward force, so WASD works as in a normal jump.
  * The character is never anchored, and the spin never teleports it.
  * `Humanoid.AutoRotate` is switched off only during the spin, so Roblox's turn-to-face logic
    doesn't fight it. It is restored to its saved value whenever the spin stops.
* **Attack** is a new `AttackController`. Attacking isn't movement, so it has its own
  controller, but it registers with the same `CharacterLifecycle`. It reads
  `MovementController.GetState()` to refuse attacks while dead, pounding or landing.
  * It adds one binding (`PlatformerAttack`, gamepad R1 and the touch button) at the movement
    controls' priority.
  * The right mouse button is observed, not bound, the same way jump keys are. That keeps
    right-drag camera turning untouched. A `Click` trigger mode makes sure a camera drag never
    attacks.
* Both play animations through the new `CharacterAnimations` loader on the character's own
  Animator. The dash roll uses it too, and was moved into `AnimationConfig`.

### Tuning cheat-sheet

| I want… | Change | Default |
|---|---|---|
| a slower spin | lower `MovementConfig.SpinFloat.SpinSpeed` (peak °/s) or raise `SpinDuration` | 760, 0.75 s |
| more or fewer turns | total turn ≈ `SpinSpeed × SpinDuration × 0.64` degrees | ≈ 1 turn |
| clockwise spin | `SpinDirection = -1` | 1 |
| a longer float | raise `FloatDuration` | 0.9 s |
| a floatier hang | lower `FallGravityScale` (share of gravity felt; must stay above 0) | 0.35 |
| a softer end to the float | raise `FloatFadeTime` | 0.25 s |
| a bigger boost | raise `UpwardBoost` (added to `DoubleJump.Velocity` 52) | 8 |
| the old plain double jump | `SpinFloat.Enabled = false` | true |
| a faster attack | lower `CombatConfig.Attack.Fallback` phase times (`WindupTime`, `StrikeTime`, `HoldTime`, `RecoveryTime`), or raise `AnimationConfig.Attack.Speed` for a custom animation | 0.39 s in total |
| more attacks per second | lower `CombatConfig.Attack.Cooldown` (keep it ≥ the punch length) | 0.45 s |
| attack on press instead of release | `TriggerMode = "Press"` (camera drags will then attack too) | "Click" |
| a bigger punch | `StrikeShoulderPitch`, `WindupShoulderPitch`, `StrikeWaistTwist` | 95°, −35°, 20° |

### Multiplayer behaviour
* **Spin and float:** your client owns your character's physics, so its rotation and position
  reach other players through normal character replication. No per-frame data is sent, and the
  server only sees the existing `DoubleJump` report. The trail is local.
* **Attack with a custom animation:** tracks played on your own Animator replicate
  automatically.
* **Attack with the fallback punch:** this is a limitation. Motor6D changes made on a client
  don't replicate, so only you see the procedural punch. Supply an animation (§4.7) for everyone
  to see it.

### Rig support
* **R15:** the fallback moves the shoulder, elbow and waist.
* **R6:** the fallback moves the shoulder only, because R6 has no elbow or waist joint.
* **Spin and float:** work the same on both rigs.
* **Custom animations:** must match the rig they were authored on.

### Adding real combat later
Today there is no hitbox, damage or remote. To add combat securely:
1. Put a `Hit` marker in the attack animation, and listen for it with
   `track:GetMarkerReachedSignal("Hit")` (for the fallback, use its strike phase).
2. On that signal, `FireServer` a new `AttackRequest` remote that carries **no damage, target or
   position**.
3. On the server, check a server-side cooldown and that the attacker is alive. Then find targets
   yourself with a spatial query around the server's view of the character, and apply damage
   there. This mirrors how ground-pound impacts are validated.
