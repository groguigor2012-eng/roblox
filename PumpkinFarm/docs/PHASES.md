# Engineering phases

The game was built in five phases, one commit each. Every phase builds on the previous one and
keeps the names, remotes, schemas and signatures fixed from the moment they were introduced.

**Phases 1–4 are review checkpoints, not playable builds.** `Bootstrap` registers the final
service list from Phase 1, so a server started from an earlier commit stops with
`[Bootstrap] missing service module …`. Phase 5 is the first playable build. Test each phase with
`tests/run.sh` and the matching section of [TESTING.md](TESTING.md).

## Phase 1: Foundation, data and networking

The skeleton every other system plugs into. Full write-up and source: [phase1/PHASE1.md](phase1/PHASE1.md).

| Area | Files |
|---|---|
| Project | `default.project.json`, `selene.toml`, `pumpkinfarm.yml` |
| Shared classes | `Janitor`, `Signal`, `StateMachine`, `TokenBucket` |
| Shared utilities | `TableUtil`, `Validate`, `WeightedRandom`, `Format`, `MathUtil`, `Result`, `Clock` |
| Constants / types / data | `MatchState`, `ResultCode`, `Attributes`, `LifeState`, `CollisionGroup`, `CurrencyId`, `Types`, `Rarity`, `Palette` |
| Configuration | all 13 config modules (crops, seeds, enemies, waves, classes, weapons, defenses, economy, status effects, difficulty, match, network, audio) |
| Persistence | `DataConfig`, `ProfileTemplate`, `Migrations`, `SessionLockedStore`, `ProfileServiceWrapper`, `DataService` |
| Networking | `RemoteService`, `RemoteRateLimiter`; client `Net` |
| Currencies | `CurrencyService`, `CandyService`, `MatchCoinService` |
| Bootstrap | `Bootstrap.server.luau`, `Registry`; client `ClientBootstrap`, `ControllerRegistry`, `ClientState` |
| Tests | harness, compile check, static check, utilities / config / data / security / load specs |

## Phase 2: World, players, classes, lobby and match lifecycle

The farming, economy, shop, chest and match-loop deliverable (as briefed for Phase 2) is written up
with its full source in [phase2/PHASE2.md](phase2/PHASE2.md).

| Area | Files |
|---|---|
| World | `CollisionGroups`, `ModelFactory`, `MapBuilder` (lobby, arenas, lighting) |
| Players | `PlayerSession`, `PlayerService`, `ClassService`, `UpgradeService` |
| Effects | `StatusEffectService`, `StunService`, `EffectService` |
| Matches | `Match` (state machine), `FarmCore`, `MatchService`, `LobbyService`, `CleanupService`, `DifficultyService` |
| Client | `UIKit`, `Panels`; Notification, Audio, HUD, WaveUI, Lobby, Class controllers |
| Tests | difficulty spec |

## Phase 3: Farming, economy and extraction

| Area | Files |
|---|---|
| Farming | `Crop`, `CropService`, `SeedService`, `SeedShop`, `SeedShopService` |
| Chest and rewards | `HarvestChest`, `HarvestChestService`, `RewardService` |
| Extraction | `EscapeDoor`, `EscapeService` |
| Client | SeedShop, Crop, HarvestChest, Escape controllers |
| Tests | economy and transactions specs |

## Phase 4: Combat, AI, defenses and waves

The enemy AI and wave spawning deliverable (as briefed for Phase 3) is written up with its full
source in [phase3/PHASE3.md](phase3/PHASE3.md).

| Area | Files |
|---|---|
| Combat | `Weapon`, `MagicStaff`, `ReaperScythe`, `WeaponService`, `DamageService`, `ProjectileSystem` |
| AI core | `AIScheduler`, `PathQueue`, `Navigator`, `TargetSelector`, `MoverRig`, `UndergroundRouter`, `EnemyBase`, `EnemyService` |
| Enemies | `ZombieFarmer`, `ZombieMole`, `BlightedScarecrow`, `PlagueCrow`, `Witch`, `CursedHarvester` |
| Defenses | `Defense`, `Barricade`, `Sentry`, `BarricadeService`, `SentryService`, `DefenseService` |
| Waves | `WaveComposer`, `WaveSpawner`, `WaveService` |
| Client | Weapon, Effects, BossBar, DefenseShop controllers |
| Tests | wave and router specs |

## Phase 5: Hardening, debug tools, verification and docs

| Area | Files |
|---|---|
| Debug | `DebugConfig`, `DebugService` (gated chat commands) |
| Verification | `tests/run.sh`, end-to-end server simulation (`tests/simulate.luau`, `tests/sim/`), `TESTING.md` Studio test plan |
| Docs | `README.md`, `ARCHITECTURE.md`, `PHASES.md` |

Review fixes found while hardening and applied across phases:
- the Mole's tunnel smoothing could squeeze diagonally between two bedrock cells (now has
  width; regression test in `router_spec`)
- enemies pathed to the centre of solid targets (now `TargetSelector.GetApproachPoint`), and
  `ClosestNoPath` paths are used instead of walking straight into fences
- player characters join the `Players` collision group (players walk through their own defenses)
- procedural enemy humanoids use the R15 rig type so `HipHeight` is honoured
- profile release by another server or backend kicks the player (both backends)
- players spawn in the lobby immediately while their profile loads
- touch placement uses `ScreenPointToRay` (touch positions exclude the top-bar inset)
- enemies claim network ownership only once their root is in the Workspace (`IsDescendantOf`), found by the end-to-end simulation

## Completion checklist

| Requirement | Where |
|---|---|
| ✅ Lobby | `LobbyService`, `MapBuilder.BuildLobby`, `LobbyController` |
| ✅ Match creation | `MatchService.CreateMatch`, arena slots |
| ✅ Match lifecycle | `Match` state machine (11 states) |
| ✅ Randomized Seed Shop | `SeedShop.GenerateStock`, `SeedShopService` |
| ✅ Seed inventory | `profile.Seeds`, `SeedService`, seed pouch UI |
| ✅ Crop planting | `CropService.Plant` (slot-based, validated) |
| ✅ Crop growth | `Crop:Update`, 4 stages, Green Thumb upgrade |
| ✅ Crop damage | `Crop:TakeDamage` (vulnerability per attacker type, specials) |
| ✅ Harvesting | `CropService.Harvest` |
| ✅ Harvest Chest | `HarvestChest`, `HarvestChestService`, HarvestUI |
| ✅ Match Coins | `MatchCoinService` |
| ✅ Global Candies | `CandyService`, `DataService` |
| ✅ Escape Door | `EscapeDoor`, `EscapeService`, EscapeUI |
| ✅ Continue mechanic | Extraction → ContinuePreparation, `ContinueLevel` |
| ✅ 30-second preparation timer | `MatchConfig.Phases.ContinuePreparation`, WaveUI countdown |
| ✅ Wave spawning | `WaveComposer`, `WaveSpawner`, `WaveService` |
| ✅ 1.2× wave scaling | `DifficultyConfig.Curves` + `DifficultyService` |
| ✅ Zombie Farmer | `AI/ZombieFarmer` |
| ✅ Zombie Mole | `AI/ZombieMole` |
| ✅ Mole underground state machine | 10-state `StateMachine` in `ZombieMole` |
| ✅ Mole raycasting | `UndergroundRouter.ForArena` probe, resurface box checks |
| ✅ Blighted Scarecrow | `AI/BlightedScarecrow` |
| ✅ Scarecrow stun | `StunService` (non-stacking, immunity, anti-movement) |
| ✅ Plague Crows | `AI/PlagueCrow` (MoverRig flight) |
| ✅ Witch | `AI/Witch` |
| ✅ Witch slowing projectile | ballistic `ProjectileSystem` potion + `Slowed` |
| ✅ Witch minion spawning | `Witch:_summon`, MaxMinions cap |
| ✅ Cursed Harvester | `AI/CursedHarvester` |
| ✅ Boss aura | `BossAura` status pulse |
| ✅ Boss every 10 waves | `WaveConfig.BossEvery`, `BossWave` state |
| ✅ Barricades | `Barricade`, `BarricadeService`, PathfindingModifier |
| ✅ Sentries | `Sentry`, `SentryService` |
| ✅ Class system | `ClassConfig`, `ClassService` |
| ✅ Witch class / Magic Staff | `MagicStaff` (35 dmg, 12 AoE, 1.2 s) + Hex Nova |
| ✅ Knight class / Reaper Scythe | `ReaperScythe` (75 dmg, 10 cleave, 1.5 s) + Reaping Whirl |
| ✅ Combat validation | `WeaponService` intent pipeline |
| ✅ Status effects | `StatusEffectService` |
| ✅ Remote security | `RemoteService` guard pipeline, schemas |
| ✅ Rate limiting | `RemoteRateLimiter` |
| ✅ ProfileService-ready persistence | `ProfileServiceWrapper` (ProfileService or built-in session-locked store) |
| ✅ Data reconciliation | `Migrations` + `TableUtil.Reconcile` |
| ✅ Match cleanup | `CleanupService`, Janitors, orphan sweep |
| ✅ UI architecture | `UIKit`, `Panels`, 14 controllers |
| ✅ Boss HUD | `BossBarController` |
| ✅ Escape UI | `EscapeController` |
| ✅ Shop UI | `SeedShopController` |
| ✅ Harvest UI | `HarvestChestController` |
| ✅ Multiplayer support | up to 4 players per match, 4 matches per server, team chest |
| ✅ Performance safeguards | ARCHITECTURE §11 |
| ✅ Testing procedures | TESTING.md + `tests/` |
