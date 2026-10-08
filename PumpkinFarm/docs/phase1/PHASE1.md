# Phase 1/5: Foundation

This is the Phase 1 deliverable for Protect the Pumpkin Farm: the hierarchy, object names and
attributes, the bootstraps, the network layer, configuration, data, players, currencies and the
match state machine.

The source is not repeated here. **[PHASE1_SOURCE.md](PHASE1_SOURCE.md)** holds the complete,
current Luau source of all 55 Phase 1 files (6,500+ lines), each under its exact Studio path. It is
generated from the repository by `tools/bundle_phases.py`, so it always matches the code.

> **Status.** All five phases are already implemented in this repository, and Phase 1 is the
> foundation they sit on. The Phase 1 files below are the final, tested versions. Advanced enemy
> AI lives in `Server/AI` (Phase 4) and is not part of this phase. Phase 1 cannot run on its own:
> `Bootstrap` registers all 29 services, and `Match`, `PlayerService` and `MatchService` use
> later-phase modules (`FarmCore`, `MapBuilder`, `CollisionGroups`, and other services through the
> Registry). To run anything, open the full place (`rojo build`), which contains every phase.

Contents:
1. [Studio hierarchy](#1-studio-hierarchy)
2. [Object names and attributes](#2-object-names-and-attributes)
3. [Shared foundation modules](#3-shared-foundation-modules)
4. [Server bootstrap](#4-server-bootstrap)
5. [Client bootstrap](#5-client-bootstrap)
6. [Remote creation](#6-remote-creation)
7. [Remote validation](#7-remote-validation)
8. [Remote rate limiter](#8-remote-rate-limiter)
9. [Configuration modules](#9-configuration-modules)
10. [Data architecture](#10-data-architecture)
11. [PlayerService](#11-playerservice)
12. [CurrencyService](#12-currencyservice)
13. [MatchService state machine](#13-matchservice-state-machine)
14. [Service dependencies](#14-service-dependencies)
15. [Source](#15-source)
16. [Create these objects in Studio](#16-create-these-objects-in-studio)
17. [Phase 1 verification checklist](#17-phase-1-verification-checklist)

---

## 1. Studio hierarchy

Legend: `[F]` Folder, `[M]` ModuleScript, `[S]` Script, `[L]` LocalScript. Marked *runtime*:
created by code at server start, so do not create it yourself.

```
ReplicatedStorage
├── Shared [F]
│   ├── Classes [F]      Janitor [M]  Signal [M]  StateMachine [M]  TokenBucket [M]
│   ├── Config [F]       NetworkConfig [M]  CropConfig [M]  SeedConfig [M]  EnemyConfig [M]
│   │                    WaveConfig [M]  ClassConfig [M]  WeaponConfig [M]  DefenseConfig [M]
│   │                    EconomyConfig [M]  StatusEffectConfig [M]  MatchConfig [M]
│   │                    DifficultyConfig [M]  AudioConfig [M]
│   ├── Constants [F]    MatchState [M]  LifeState [M]  ResultCode [M]  Attributes [M]
│   │                    CollisionGroup [M]  CurrencyId [M]
│   ├── Types [F]        Types [M]
│   ├── Utilities [F]    TableUtil [M]  Validate [M]  Result [M]  Clock [M]  MathUtil [M]
│   │                    Format [M]  WeightedRandom [M]
│   └── Data [F]         Rarity [M]  Palette [M]
├── Assets [F]           (optional art overrides; empty folders are fine)
│   ├── Enemies [F]  Crops [F]  Weapons [F]  UI [F]  Effects [F]
└── Remotes [F]          runtime: RemoteService:Init creates 24 remotes from NetworkConfig

ServerScriptService
└── Server [F]
    ├── Bootstrap [S]            the only server Script
    ├── Registry [M]             service locator
    ├── DebugConfig [M]          (Phase 5)
    ├── Data [F]                 DataConfig [M]  ProfileTemplate [M]  Migrations [M]
    │                            SessionLockedStore [M]  ProfileServiceWrapper [M]
    ├── Services [F]             Phase 1: RemoteService  DataService  CandyService
    │                            MatchCoinService  CurrencyService  PlayerService  MatchService
    │                            (29 services in total by Phase 5)
    ├── Systems [F]              Phase 1: RemoteRateLimiter
    ├── Classes [F]              Phase 1: PlayerSession  Match
    └── AI [F]                   (Phase 4)

ServerStorage
├── Packages [F]                 optional: ProfileService [M] (loleris)
└── Maps [F]                     optional: FarmArena [Model]

StarterPlayer                    CameraMaxZoomDistance = 60
└── StarterPlayerScripts
    └── Client [F]
        ├── ClientBootstrap [L]  the only client script
        ├── Modules [F]          Phase 1: ControllerRegistry [M]  Net [M]  ClientState [M]
        │                        (UIKit, Panels: Phase 2)
        └── Controllers [F]      14 controllers (Phases 2-4)

StarterGui                       intentionally empty (see below)

Workspace                        StreamingEnabled = false
├── Lobby [F]                    runtime: built by LobbyService (Phase 2)
└── Matches [F]                  runtime: one Match_<id> folder per running match

Players                          CharacterAutoLoads = false
Lighting                         Technology = Future
```

**StarterGui is empty on purpose.** Each client controller builds its own ScreenGui (`MainHUD`,
`ShopUI`, `HarvestUI`, `EscapeUI`, `ClassUI`, `BossUI`, and others) straight into `PlayerGui` with
`ResetOnSpawn = false`. That way every element the code uses is guaranteed to exist, and the UI
needs no binary assets. The ScreenGui names match the brief.

**Why `CharacterAutoLoads = false`.** The server decides where and when a character exists: in the
lobby on join, at an arena spawn in a match, and never during a wave if downed. PlayerService calls
`LoadCharacter` itself.

**Why `StreamingEnabled = false`.** Clients read match folders, crops and enemies by attribute, and
arenas are small. Streaming would add `WaitForChild` races for no gain.

## 2. Object names and attributes

You never create attributes by hand. The server writes them all at runtime. Clients read them for
display only, and the names are constants in `Shared.Constants.Attributes`.

### On each `Player`

| Attribute | Type | Values | Written by | Read by |
|---|---|---|---|---|
| `ProfileStatus` | string | `Loading` · `Loaded` · `Failed` | DataService | LobbyController (Test mode / failure banner) |
| `Candies` | number | permanent balance | DataService (after every change) | HUD |
| `MatchCoins` | number? | match balance; nil outside a match | MatchCoinService | HUD, shops |
| `LifeState` | string | `Loading` `Lobby` `Queued` `InMatch` `Downed` `Escaped` | PlayerSession:SetLifeState | HUD, lobby |
| `ClassId` | string | `Witch` / `Knight` | ClassService | HUD, weapon UI |
| `MatchId` | string? | id of the current match | Match | ClientState (binds `Matches.Match_<id>`) |
| `Effects` | string | JSON of active status effects | StatusEffectService | HUD |
| `Queued` | boolean | in the lobby queue | LobbyService | LobbyController |
| `QueueEndsAt` | number | server time the queue launches | LobbyService | LobbyController |
| `QueueSize` | number | players queued | LobbyService | LobbyController |

### On each match folder `Workspace.Matches.Match_<id>` (Folder)

| Attribute | Type | Meaning |
|---|---|---|
| `MatchId` | string | match id |
| `State` | string | a `MatchState` value |
| `Wave` | number | current wave (0 before wave 1) |
| `IsBossWave` | boolean | current wave contains the Cursed Harvester |
| `EnemiesRemaining` | number | alive + still to spawn |
| `PhaseEndsAt` | number | `Workspace:GetServerTimeNow()` when the timed phase ends (clients count down to it) |
| `ContinueLevel` | number | how many times the team chose CONTINUE |
| `DifficultyMultiplier` | number | 1, 1.5, 2.25… |
| `CoreHealth` / `CoreMaxHealth` | number | Great Pumpkin |
| `ChestValue` | number | Harvest Chest Candy value |
| `Objective` | string | HUD objective line |
| `BossActive`, `BossName`, `BossHealth`, `BossMaxHealth`, `BossAuraRadius`, `BossEnraged` | mixed | boss HUD |

Phase 1 writes `MatchId`, `State`, `PhaseEndsAt`, `Wave`, `ContinueLevel`, `DifficultyMultiplier`
and `Objective`. The other attributes are declared now and written by later-phase services.
Entity attributes (crops, enemies, defenses, plot slots) are declared in `Attributes` and documented
in `docs/ARCHITECTURE.md` §2.1.

### Name contracts

| Name | Defined in | Notes |
|---|---|---|
| Remote names (24) | `NetworkConfig.Remotes` | under `ReplicatedStorage.Remotes` |
| Collision groups | `CollisionGroup`: `PF_Players` `PF_Enemies` `PF_Defenses` `PF_Ghost` | registered by `Systems.CollisionGroups` |
| Result codes | `ResultCode` (27 codes + player-facing `Messages`) | every RemoteFunction returns `{ Ok, Code, Data }` |
| Currencies | `CurrencyId`: `MatchCoins`, `Candies` | |

## 3. Shared foundation modules

All live in `ReplicatedStorage.Shared`. They are pure Luau with no service access, so client and
server can both require them. Configs and constants are deep-frozen.

| Module | Purpose |
|---|---|
| **Constants** `MatchState` | the 11 match states |
| `LifeState` | the 6 player flow states |
| `ResultCode` | response codes and the toast message for each |
| `Attributes` | every replicated attribute name |
| `CollisionGroup`, `CurrencyId` | group and currency names |
| **Types** `Types` | shared exported types (Result, Profile shape, definitions) |
| **Utilities** `TableUtil` | `DeepCopy`, `DeepFreeze`, `Reconcile` (fill missing keys, never overwrite), `Count`, `Keys`… |
| `Validate` | network schema checker (§7) |
| `Result` | `Result.Ok(data)`, `Result.Fail(code)` constructors |
| `Clock` | `Clock.Now()` = `Workspace:GetServerTimeNow()`, the shared clock for `PhaseEndsAt` countdowns |
| `MathUtil`, `Format`, `WeightedRandom` | maths (ballistics, clamps), number and time formatting, seeded weighted picks |
| **Data** `Rarity`, `Palette` | rarity tiers and colours, the UI and world colour palette |
| **Classes** `Janitor` | cleanup: `Add(item, method?)`, `AddKeyed(key, item)`, `Connect(signal, fn)`, `Remove(key)`, `Detach(key)`, `Cleanup()`, `Destroy()`. Cleans in reverse order and handles tasks added during cleanup. Every Match, PlayerSession and entity owns one. |
| `Signal` | typed in-process events (`Connect`, `Once`, `Fire`, `Wait`, `DisconnectAll`). A failing handler can't break the others. |
| `StateMachine` | named states with `Enter`/`Exit`/`Update` and an allowed-transition table. Illegal transitions are refused and reported. |
| `TokenBucket` | the rate-limit primitive (capacity + refill per second) |

## 4. Server bootstrap

`ServerScriptService.Server.Bootstrap` is the **only server Script**:

1. `CollisionGroups.Setup()` and `MapBuilder.ConfigureLighting()`
2. require every module in `SERVICE_ORDER` and store it in `Registry[name]`. A missing module stops
   startup with `[Bootstrap] missing service module <name>`.
3. **Init phase.** `service:Init()` for every service, in order. Wiring only: create instances and
   tables. No calls to other services.
4. **Start phase.** `service:Start()` for every service, in order. Connect events, bind remote
   handlers and start loops. Any service may be called now.
5. `RemoteService:VerifyHandlers()` warns about any client→server remote without exactly one handler.
6. Prints `[Bootstrap] Protect the Pumpkin Farm server ready (29 services)`.

Each `Init`/`Start` runs inside `xpcall`, so one failing service is reported with a traceback and
the rest still start.

**Registry pattern.** No service requires another service. Each one does
`local Services = require(Server.Registry)` and looks up `Services.X` *at call time*. The require
graph therefore has no cycles, and the start order is the only coupling.

Order of the Phase 1 services (the full list of 29 is in `Bootstrap`):

| # | Service | Why here |
|---|---|---|
| 1 | RemoteService | creates `ReplicatedStorage.Remotes` in Init, so it exists before any handler is bound and before clients call `WaitForChild` |
| 2 | DataService | picks the persistence backend in Init; profiles must load before anything reads them |
| 3-5 | CandyService, MatchCoinService, CurrencyService | currency layers over DataService / memory |
| … | (Phase 2-4 services) | |
| 26 | MatchService | starts the central match update loop |
| 28 | PlayerService | starts last among gameplay services, because its `PlayerAdded` handler touches everything |

## 5. Client bootstrap

`StarterPlayerScripts.Client.ClientBootstrap` is the **only client script**. It mirrors the server:

1. wait for `game.Loaded`
2. require each controller in `CONTROLLER_ORDER` (`WaitForChild(name, 10)`) into
   `ControllerRegistry`
3. `Init` all controllers (build UI, no cross-controller calls)
4. `ClientState.Start()`: subscribe to the server→client remotes, request a snapshot, bind the match
   folder from the `MatchId` attribute
5. `Start` all controllers (connect events)

Phase 1 client modules:

| Module | Role |
|---|---|
| `ControllerRegistry` | locator filled by ClientBootstrap (same pattern as the server Registry) |
| `Net` | `Net:Invoke(name, ...)` → `{ Ok, Code, Data }` (never throws), `Net:Fire`, `Net:On`. Looks remotes up by name under `ReplicatedStorage.Remotes`. Sends intent only. |
| `ClientState` | read-only cache: `Profile`, `Shop`, `Chest`, `Extraction`, `MatchFolder`, change signals, `ObserveMatchAttribute(name, cb)`. Display only, never trusted by the server. |

## 6. Remote creation

`NetworkConfig.Remotes` is the **single source of truth**. During `Init`, `RemoteService`:

1. destroys any stale `ReplicatedStorage.Remotes` folder left in the place file
2. creates a new `Folder` named `Remotes`, and inside it one `RemoteEvent` / `RemoteFunction` per
   entry
3. parents the folder only once it is complete, so clients never see a half-built folder
4. builds the rate limiter from every entry's `RateLimit`

There are 24 remotes: 17 client→server and 7 server→client.

| Client → server | Class | Arguments (validated) | Rate (capacity / refill per s) |
|---|---|---|---|
| RequestJoinQueue, RequestLeaveQueue | Function | none | 3 / 0.5 |
| RequestSelectClass, RequestPurchaseClass, RequestPurchaseUpgrade | Function | id | 3-4 / 0.5-1 |
| RequestUpdateSettings | Event | enum, boolean | 4 / 1 |
| RequestSnapshot | Function | none | 3 / 0.5 |
| RequestBuySeed | Function | id, integer stock version | 6 / 3 |
| RequestPlant | Function | plot id, slot 1-64, seed id | 6 / 3 |
| RequestHarvest | Function | crop uid | 8 / 4 |
| RequestPurchaseDefense | Function | id, Vector3, rotation −360…360 | 4 / 2 |
| RequestUpgradeDefense | Function | uid | 4 / 2 |
| RequestPurchaseItem | Function | id | 4 / 2 |
| RequestAttack | Event | aim Vector3, sequence integer | 5 / 3 |
| RequestUseAbility | Event | id, aim Vector3 | 3 / 1 |
| RequestEscape, RequestContinue | Function | none | 3 / 0.5 |

Server → client (all RemoteEvents): `ProfileUpdated`, `ShopUpdated`, `ChestUpdated`,
`ExtractionUpdated`, `MatchEvent`, `Notify`, `Effect`. `Effect` is culled beyond 400 studs from
each client.

Remotes carry **intent only**. "I attack towards this point" is allowed. "I hit enemy X for 75" is
not. The server computes every outcome.

## 7. Remote validation

Every client→server call goes through one pipeline in `RemoteService`, before the handler runs:

1. **Sender check.** The player must still be in the game.
2. **Rate limit.** A token is taken per player per remote (§8). If none is left, the call is
   rejected with `RateLimited`.
3. **Schema.** `Validate.CheckArgs(args, n, schema)` checks:
   - the exact argument count; extra arguments are rejected
   - the kind of each argument: `string` (max length + Lua pattern), `integer`/`number` (min/max,
     never NaN or ±inf), `boolean`, `Vector3` (finite components, max magnitude), `enum`
   - a failure is rejected with `InvalidPayload`
4. **Handler.** It runs in `xpcall`. An error becomes `ServerError` (logged with a traceback),
   never a crashed thread.
5. **Violations.** Every rejection is counted per player in a 30 s window. Above 40, a warning is
   logged, and with `NetworkConfig.Security.KickOnAbuse` the player is kicked.

RemoteFunctions always return `{ Ok: boolean, Code: string, Data: any? }`. RemoteEvents drop bad
calls silently. Handlers then apply game rules (state, ownership, range, funds) and return codes
such as `InvalidState`, `OutOfRange` or `InsufficientFunds`.

API: `OnEvent(name, fn)`, `OnInvoke(name, fn)`, `FireClient`, `FireClients`, `FireAllClients`,
`ReportViolation`, `GetViolationCount`, `VerifyHandlers`. Binding a second handler to the same
remote is an error.

## 8. Remote rate limiter

`Server.Systems.RemoteRateLimiter` keeps one `TokenBucket` per player per remote, created lazily
with that remote's `{ Capacity, Refill }`. It runs before any payload decoding, which is the
cheapest place to reject spam. `limiter:Check(player, remote, now)` → boolean. Buckets are removed
on `PlayerRemoving`. Spamming one remote never throttles a different remote or another player
(covered by `security_spec`).

## 9. Configuration modules

All in `ReplicatedStorage.Shared.Config`, deep-frozen and readable by clients for display. Prices
and stats are enforced on the server only.

| Module | Holds |
|---|---|
| `CropConfig` | Neon Star-Fruit, Ghost Pepper, Void Pumpkin + extras: growth time, stages, health, Candy value, vulnerabilities, specials |
| `SeedConfig` | shop rules per seed: price, rarity, stock range, unlock wave, per-player limit |
| `EnemyConfig` | per enemy: health, speed, damage, range, coin reward, crop vulnerability, AI module, special parameters (mole dig, scarecrow leap/stun, crow theft, witch potion/minions, boss aura/crush) |
| `WaveConfig` | composition: unlock waves, weights, caps, boss every 10, specialist share |
| `ClassConfig` | Witch and Knight: price, health, speed, weapon, ability, costume |
| `WeaponConfig` | Magic Staff (35 dmg, 12 AoE, 1.2 s) and Reaper Scythe (75 dmg, 10 cleave, 1.5 s), abilities, validation tolerances |
| `DefenseConfig` | barricades, sentries, accessories, utilities: Match Coin prices, health, levels |
| `EconomyConfig` | Match Coin starting amount and rewards, Candy conversion, risk bonus, soft-lock grant, permanent upgrades |
| `StatusEffectConfig` | Stunned (2 s, non-stacking, immunity), Slowed, BossAura, SpawnProtection… |
| `MatchConfig` | players per match, concurrent matches, phase durations (Waiting 15, Starting 5, Intermission 40/25, PreparingWave 4, WaveComplete 4, Extraction 30, ContinuePreparation 30, MatchEnding 8), extraction every 5 waves, update rate, shop open states |
| `DifficultyConfig` | ×1.2 per-wave curve with soft and hard caps, Continue ×1.5, per-stat factors |
| `NetworkConfig` | remotes (§6) and security settings |
| `AudioConfig` | sound ids and volumes (empty ids are skipped) |

## 10. Data architecture

```
DataService ──► ProfileServiceWrapper ──► ProfileService           (if ServerStorage.Packages.ProfileService exists)
                                     ├─► SessionLockedStore(DataStore)   (live servers, default)
                                     └─► SessionLockedStore(Memory)      (Studio by default, or DataStores unavailable)
```

| Part | File | What it does |
|---|---|---|
| Wrapper | `Data/ProfileServiceWrapper` | picks a backend and exposes one `Store` / `Profile` surface (`Data`, `IsTemporary`, `IsActive`, `Reconcile`, `Save`, `Release`, `ListenToRelease`) |
| Session locking | `Data/SessionLockedStore` | `UpdateAsync` lock `{SessionId, PlaceId}`. Takes over a lock older than 600 s (crashed server), retries 8 × 5 s while another server releases. Every save checks the lock is still ours; if it was stolen the write is cancelled and the player kicked. Saves are serialized and coalesced, retried with backoff, and skipped when the request budget is low. |
| Template | `Data/ProfileTemplate` | the schema below |
| Schema version | `ProfileTemplate.Version` = `Migrations.CurrentVersion` = 1 | |
| Migrations | `Data/Migrations` | `Steps[n]` upgrades version n → n+1. Step 0→1 converts legacy array-style costumes and a legacy `Candy` key. Data newer than the server is refused (no load) instead of being downgraded. |
| Reconciliation | `TableUtil.Reconcile` | after migration, adds missing template keys and never overwrites existing values |
| Settings | `Data/DataConfig` | store `PumpkinFarm_Profiles_v1`, key `Player_<UserId>`, autosave 60 s, stale lock 600 s, shutdown timeout 25 s, `UseMockInStudio = true` |

Profile schema (Version 1):

```lua
{
    Candies = 120,
    UnlockedCostumes = { Knight = true },
    EquippedCostume = nil,              -- nil = ClassConfig.DefaultClassId
    Seeds = { NeonStarFruit = 3 },
    ClassStats = {},                    -- [classId] = { MatchesPlayed, Kills, HighestWave }
    PermanentUpgrades = {},             -- [upgradeId] = level
    Statistics = { TotalWaves = 0, TotalKills = 0, TotalHarvested = 0, BossesDefeated = 0,
                   MatchesPlayed = 0, MatchesEscaped = 0, HighestWave = 0 },
    Settings = { MusicEnabled = true, EffectsEnabled = true },
    Version = 1,
}
```

**Player lifecycle (DataService + PlayerService).**
- **Join:** `ProfileStatus = Loading` → load (with lock) → migrate → reconcile → add default classes
  → `ProfileStatus = Loaded`, `Candies` attribute set, `ProfileUpdated` sent → `ProfileLoaded` fires.
- **Failed load:** `ProfileStatus = Failed`. The player stays in the lobby, sees why, and cannot
  queue. Every grant or purchase returns false, so nothing can be duplicated or lost later.
- **Changes:** only through `DataService:Update(player, mutator)`. A mutator that errors is rolled
  back. Replication is coalesced to one `ProfileUpdated` per frame.
- **Leave:** leave the queue → leave the match (stats committed) → `ReleaseProfile` (final save +
  unlock).
- **Autosave:** every 60 s, which also refreshes the session lock.
- **Shutdown:** `game:BindToClose` → `store:ReleaseAllAsync(25)` saves and unlocks every profile.
  It is skipped in Studio with the memory backend, so stopping a playtest is instant.
- **External release** (another server took the lock, or ProfileService released it): the player is
  kicked, so two servers can never write the same profile.

## 11. PlayerService

`PlayerService` owns one `PlayerSession` per player (`Classes/PlayerSession`). The session holds:
- `LifeState`, mirrored to the attribute
- its character binding (`BindCharacter`, `GetRoot`, `IsAlive`)
- health (`TakeDamage`, `Heal`)
- per-match stats (`ResetMatchState`)
- coin multiplier and recomputed stats
- a Janitor that is cleaned on leave

| Event | Behaviour |
|---|---|
| `PlayerAdded` (and players already present when Start runs) | create the session → spawn in the lobby immediately → load the profile in parallel → apply the equipped class |
| Character | `LoadCharacter` is called by the server only. The character joins the `PF_Players` collision group. |
| Death in the lobby | respawn in the lobby after `MatchConfig.Lobby.RespawnDelay` |
| Death in a match | `Downed` until the wave ends (Match revives them), then a team-wipe check |
| `PlayerRemoving` | queue → match → profile release → session destroy |
| `RequestSnapshot` | profile + shop + chest + extraction, for a UI that reloads |
| `RequestUpdateSettings` | persisted boolean settings |

API: `GetSession`, `GetSessions`, `SpawnAsync`, `SpawnInLobby`, `SpawnInMatch`, `Notify`,
`GetSnapshot`. Signals: `SessionAdded`, `SessionRemoving`, `CharacterDied`.

## 12. CurrencyService

| Service | Currency | Storage | Rules |
|---|---|---|---|
| `CandyService` | **Global Candies** (permanent) | profile via `DataService:Update` | positive integers only; every change has a reason; nothing when the profile isn't loaded; `TrySpend` is check-and-deduct in one non-yielding call, so double clicks can't overspend |
| `MatchCoinService` | **Match Coins** (temporary) | server memory, keyed by player | `Reset(player, start)` on match start, `Clear` on escape, defeat or leave, so coins never leak into persistence or another match. Mirrored to the `MatchCoins` attribute for display. |
| `CurrencyService` | both | none (router) | `Get`, `CanAfford`, `TrySpend(player, currencyId, amount, reason)`, `Grant(...)`, so purchase and reward code doesn't care which currency a price uses |

## 13. MatchService state machine

`Classes/Match` wraps a `StateMachine` with the 11 `MatchState` states and an explicit
allowed-transition table. An illegal transition is refused and reported.

```
Waiting → Starting → Intermission → PreparingWave → WaveActive | BossWave → WaveComplete
WaveComplete → Intermission            (wave % 5 ≠ 0)
WaveComplete → Extraction              (wave % 5 = 0)
Extraction → ContinuePreparation (someone chose CONTINUE, 30 s, difficulty ×1.5) → PreparingWave
Extraction → MatchEnding               (everyone escaped)
any playing state → MatchEnding        (Great Pumpkin destroyed / team wiped / abandoned)
MatchEnding → Cleanup
```

Each timed state sets `PhaseEndsAt = Clock.Now() + duration` (durations from `MatchConfig.Phases`)
and moves on when the time is up. `State` is mirrored to the match folder attribute.

`MatchService`:
- allocates arena slots (up to `MaxConcurrentMatches`)
- creates matches with `CreateMatch(sessions)`. If creation fails, every session is reset.
- runs **one** update loop for all matches at `MatchConfig.UpdateRate`
- calls `InitMatch(match)` on each per-match service in `MatchServices` order and `CleanupMatch` in
  reverse (through CleanupService)
- removes players (`RemoveSession(session, "Escaped" | "Left")`)
- destroys finished matches

The full per-state table is in `docs/ARCHITECTURE.md` §4.

## 14. Service dependencies

Two kinds of edge:
- **require**: a static module import.
- **Registry**: a runtime call through `Services.X`, made only after Init.

No service requires another service, so the require graph is acyclic.

| Service | Requires (static) | Calls through Registry (runtime) | Why |
|---|---|---|---|
| RemoteService | NetworkConfig, ResultCode, Result, Validate, RemoteRateLimiter | none | the base layer; everything else binds to it |
| DataService | ProfileServiceWrapper, ProfileTemplate, Migrations, DataConfig, TableUtil, Signal, Attributes, ClassConfig, EconomyConfig | RemoteService | sends `ProfileUpdated` |
| CandyService | Registry | DataService | Candies live in the profile |
| MatchCoinService | EconomyConfig, Attributes | none | memory only |
| CurrencyService | CurrencyId, Registry | CandyService, MatchCoinService | routes by currency |
| PlayerService | PlayerSession, CollisionGroups, CollisionGroup, LifeState, MatchConfig, Signal, Result | DataService (load/release), ClassService (apply class), LobbyService (queue, spawn), MatchService (leave), StatusEffectService, WeaponService, RemoteService (snapshot/settings), SeedShopService / HarvestChestService / EscapeService (snapshot) | owns the join/leave sequence, so it touches every system a player is in |
| MatchService | Match, MatchConfig, LifeState | PlayerService, CleanupService, RewardService, MatchCoinService, WeaponService, StatusEffectService, every service in `MatchServices` | creates and tears down matches |
| Match (class) | StateMachine, Janitor, Signal, FarmCore, MapBuilder, configs, Clock, Format | MatchCoinService, PlayerService, DifficultyService, WaveService, EscapeService, HarvestChestService, SeedShopService, … | each state's enter/exit drives the per-match services |

Rules that keep this safe:
1. **Init never calls another service.** Only Start and later do, and by then every module is
   registered.
2. **Order encodes readiness.** Each service is placed after anything it reads during its own
   Start: RemoteService first, DataService second, PlayerService last.
3. **Clients depend only on Shared and the Remotes folder.** They never see server modules.

## 15. Source

Complete source: **[PHASE1_SOURCE.md](PHASE1_SOURCE.md)**, 55 files grouped as above, each under
its Studio path and instance class. To regenerate it after a code change, run
`python3 tools/bundle_phases.py`.

## 16. Create these objects in Studio

**Recommended: don't create anything by hand.** Use the built place:

```sh
cd PumpkinFarm
rojo build default.project.json -o ProtectThePumpkinFarm.rbxl
```

Open `ProtectThePumpkinFarm.rbxl` in Studio, or run `rojo serve` and connect the Rojo plugin.

**Manual setup** (if you're not using Rojo). The script type matters: a `Script` where a
`ModuleScript` belongs will not work.

- [ ] **Players**: set `CharacterAutoLoads` = false
- [ ] **Workspace**: set `StreamingEnabled` = false
- [ ] **Lighting**: set `Technology` = Future
- [ ] **StarterPlayer**: set `CameraMaxZoomDistance` = 60
- [ ] **ReplicatedStorage**:
  - [ ] Folder `Shared`, containing Folders `Classes`, `Config`, `Constants`, `Types`, `Utilities`,
    `Data`
  - [ ] in each, the ModuleScripts listed in §1, named exactly, with the source from
    PHASE1_SOURCE.md
  - [ ] Folder `Assets` with Folders `Enemies`, `Crops`, `Weapons`, `UI`, `Effects`
  - [ ] **do not** create `Remotes`. RemoteService creates it and deletes any existing one.
- [ ] **ServerScriptService**:
  - [ ] Folder `Server`
  - [ ] **Script** `Bootstrap` and ModuleScripts `Registry`, `DebugConfig`
  - [ ] Folders `Data`, `Services`, `Systems`, `Classes`, `AI` with their ModuleScripts
- [ ] **ServerStorage**:
  - [ ] Folder `Packages` (optional: ModuleScript `ProfileService`)
  - [ ] Folder `Maps`
- [ ] **StarterPlayer → StarterPlayerScripts**:
  - [ ] Folder `Client`
  - [ ] **LocalScript** `ClientBootstrap`
  - [ ] Folders `Modules` and `Controllers` with their ModuleScripts
- [ ] **StarterGui**: leave empty
- [ ] **Workspace**: leave empty apart from the default Camera/Terrain. `Lobby` and `Matches` are
  built at runtime. Delete the default Baseplate/SpawnLocation; the lobby has its own spawn.
- [ ] **Attributes**: none to create. All are set at runtime (§2).
- [ ] **Saving real data in Studio** (optional): Game Settings → Security → *Enable Studio Access
  to API Services*, **and** set `DataConfig.UseMockInStudio = false`. Otherwise Studio uses the
  in-memory store, nothing is written, and the lobby shows "Test mode". Published servers always
  use DataStores.

## 17. Phase 1 verification checklist

**Automated** (`PumpkinFarm/tests/run.sh`, needs Lune):
- [ ] `compiled 123 files, 0 failures`
- [ ] selene: `0 errors`, `0 warnings`
- [ ] `static check: 0 problems`: every require resolves, every `Services.X:Method` exists, every
  remote is declared with the right direction and has exactly one handler
- [ ] specs pass. The Phase 1 specs:
  - `utilities_spec`: Janitor, Signal, StateMachine, TokenBucket, Reconcile, Validate (NaN, inf,
    huge vectors, extra args, patterns, enums)
  - `config_spec`: cross-config integrity; Staff 35/12/1.2 and Scythe 75/10/1.5; every C→S remote
    has a schema and rate limit
  - `data_spec`: migration 0→1, newer-version refusal, session locking across two servers,
    stale-lock takeover, stolen session never overwrites, no double load
  - `security_spec`: rate-limit isolation, 100-request spam admits only a handful
  - `load_spec`: every module loads
  - `transactions_spec`: rollback, no grants to unloaded players, purchase races

**In Studio** (Play, then check the Output and Explorer):
- [ ] Output shows `[DataService] persistence backend: Memory` (Studio) and
  `[Bootstrap] Protect the Pumpkin Farm server ready (29 services)`, with no `[Bootstrap] … failed`
  lines
- [ ] `ReplicatedStorage.Remotes` exists with 24 children (14 RemoteFunctions, 10 RemoteEvents)
- [ ] Your Player has `ProfileStatus = Loaded`, `Candies = 120`, `LifeState = Lobby`, `ClassId = Knight`
- [ ] You spawn in the lobby straight away (CharacterAutoLoads is off, so the server spawned you)
- [ ] Client command bar: `print(game.ReplicatedStorage.Remotes.RequestJoinQueue:InvokeServer("extra").Code)`
  prints `InvalidPayload` (extra arguments rejected)
- [ ] Client command bar:
  `for i=1,10 do print(game.ReplicatedStorage.Remotes.RequestSnapshot:InvokeServer().Code) end`
  prints `Ok` 3 times, then `RateLimited`
- [ ] Client command bar: `game.ReplicatedStorage.Remotes.RequestAttack:FireServer(Vector3.new(0/0,0,0), 1)`
  does nothing (NaN dropped) and the server keeps running
- [ ] Chat `/pf candies 1000` (debug, Studio only): the `Candies` attribute goes to 1120 and the HUD
  updates
- [ ] Join the queue at the portal: `LifeState` goes `Queued` → `InMatch`, and
  `Workspace.Matches.Match_<id>` appears with `State` changing
  `Waiting → Starting → Intermission` and `PhaseEndsAt` counting down
- [ ] `MatchCoins` appears on your Player in the match and disappears when you leave
- [ ] **Persistence** (with API access and `UseMockInStudio = false`): earn Candies, stop, play
  again, and the balance is kept. Start a 2-player local server, and each player has their own
  profile.
- [ ] **Shutdown**: stopping the server with the DataStore backend waits for the final saves (up to
  25 s) and prints no save errors
