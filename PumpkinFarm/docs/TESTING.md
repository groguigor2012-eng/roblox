# Testing

Two layers:

1. **Automated, headless** (`tests/run.sh`): compile, lint, static cross-references, 226 Lune
   specs and an end-to-end simulation of the real server running whole matches. Run it before
   every commit.
2. **Studio test plan** (below): the engine-dependent behaviour (physics, pathfinding, UI,
   replication, multiple clients). Grouped by engineering phase.

## 1. Automated checks

| Step | Tool | What it proves |
|---|---|---|
| `tests/compile_check.luau` | Lune's Luau compiler | every one of the 123 files parses and compiles |
| `selene src` | selene + `pumpkinfarm.yml` (Roblox globals) | no undefined or unused variables, no shadowed globals |
| `tests/static_check.py` | python3 | every `require` resolves; every `Services.X:Method` / `Controllers.X:Method` exists; every remote used is declared with the right direction; every client→server remote has exactly one server handler; every effect the server emits has a client renderer |
| `tests/run.luau` | Lune + `tests/harness.luau` | the specs below. The harness maps the Rojo tree onto a fake Instance hierarchy so production modules load unmodified; Workspace, Lighting, SoundService and PlayerGui are emulated Instances with small shims for engine methods Lune lacks (`Model:PivotTo/GetPivot/GetExtentsSize`, GUI and prompt events). |

| Spec | Covers |
|---|---|
| `load_spec` | all 102 shared/server modules load (top-level code, require graph, frozen configs) |
| `builders_spec` | every procedural model (7 enemies, 5 crops × 4 stages, 4 defenses, 2 weapons, core, chest, door, 2 costumes), lighting, the lobby and the full arena layout, built through Lune's Instance emulation, which rejects unknown properties and wrongly typed values like the engine. Also the `Crop` class (all growth stages, thorns, regeneration, Anchored) and `Barricade`/`Sentry` (pathfinding modifier, collision group, upgrades, repair, depletion). |
| `client_spec` | the whole client UI: every controller's `Init` in bootstrap order, all 13 ScreenGuis (`ResetOnSpawn = false`), and the data-driven panels (wardrobe, seed shop, pouch, chest, defenses, banners, toasts) rendered from sample state, including empty and locked states |
| `utilities_spec` | Janitor ordering, keyed tasks, late adds, detach; Signal isolation; StateMachine legality and nested transitions; TokenBucket; Reconcile never overwrites; payload validation (NaN, inf, huge vectors, extra args, patterns, enums); deterministic weighted random; ballistic maths |
| `config_spec` | cross-config integrity (seeds↔crops, enemies↔AI modules, classes↔weapons↔abilities, effects), crop profitability, required values from the brief (Staff 35/12/1.2, Scythe 75/10/1.5, stun 2 s non-stacking), every client→server remote has a schema and rate limit, server→client remotes are events |
| `difficulty_spec` | 1.2× health growth per wave, soft and hard caps, damped speed, monotonic curves, weighted Continue factors, per-enemy scaling, boss index, counts and pacing |
| `wave_spec` | wave 1 grunts only, deterministic plans, unlock waves and caps, boss first on boss waves, witches never lead, Continue raises specialist pressure |
| `economy_spec` | seed stock generation (guaranteed seed, MinWave, price variance and rounding, determinism), purchase checks (version, stock, per-player limits, restock reset), chest totals, risk bonus, forfeit |
| `data_spec` | template schema, migration 0→1, newer-version refusal, session locking across two servers, release then load elsewhere, stale-lock takeover, a stolen session never overwrites newer data, autosave refreshes the lock, temporary stores never write, no double load |
| `router_spec` | Mole A* routes around bedrock through the only gap, sealed targets return nil, bounds and expansion budget, no diagonal squeeze between bedrock cells (regression), probe caching, resurface point placement |
| `security_spec` | rate limiter isolation per player and remote, cleanup on leave, 100-request spam admits only a handful |
| `transactions_spec` | real DataService (in-memory store): grant validation, rollback of failing mutations, no grants to unloaded players. Real SeedShopService: charge-once, stale version, closed shop, insufficient funds, **two players racing for the last seed → exactly one wins**. ClassService and UpgradeService atomicity and caps. Real EscapeService: escape pays once, repeat decisions rejected, door range / closed door / downed, Continue keeps undecided players, nobody continuing → everyone escaped and paid exactly once. |

### End-to-end server simulation (`tests/simulate.luau`)

`tests/sim/` runs the **unmodified server** (Bootstrap, all 29 services, every AI, the real map)
in virtual time, with fake players that act only through the real remotes and chat commands:

| Piece | What it does |
|---|---|
| `sim/Scheduler.luau` | virtual-time `task` library and `os.clock`; minutes of game time run in seconds, deterministically. Errors in any thread are recorded and fail the scenario. |
| `sim/Geometry.luau` | `Workspace:Raycast`, `Spherecast`, `GetPartBoundsInBox` over the built map (oriented boxes, a 16-stud grid for static geometry, CanQuery and the Ghost group honoured), plus walking collision and ground probing |
| `sim/Engine.luau` | mounts the Rojo tree, emulates Players (characters, Backpack, Chatted, Kick), RemoteEvents/Functions, Humanoid walking (`MoveTo`, collision, ground snap, `PlatformStand` ballistics, health regeneration, `Died`), `AlignPosition`/`AlignOrientation`, and a PathfindingService backed by the Mole's A* router over the real map |

Scenarios (a script error or an unexpected warning fails the scenario; players' last events are
dumped on failure):

| Scenario | Proves |
|---|---|
| solo full loop | queue → intermission → buy seeds → plant → build a barricade → waves 1-5 cleared by a bot → harvest into the chest → door → escape → payout equals the chest value exactly once → statistics committed once → match and arena destroyed |
| duo | two players share a match; every enemy archetype spawned and observed acting (a Mole goes underground, a Witch summons minions, a Scarecrow stuns, a potion slows, crops are stolen or eaten); the Cursed Harvester spawns, the boss HUD shows and clears, its kill deposits a Cursed Core; boss wave 10 → door → one player continues, the other escapes and is paid; 30 s preparation at danger ×1.5; the farm then falls, the loss is recorded and everything is cleaned up |
| farm rules | plot ownership and its release on leave, planting cooldown, every planting rejection (no seed consumed), growth, teammate harvest, duplicate harvest, full chest keeps the crop, two players buying one seed until the stock runs out (exact stock, charged once), stale version, malformed ids, rate limiting, shop closed during waves |
| server reset | shutdown mid-wave: BindToClose runs cleanly, the chest is not paid, Match Coins never reach the profile |
| zombie mole | the full 10-state tunnel cycle under the fence, a detour around an exit blocked mid-tunnel, no teleporting, retargeting when its crop vanishes, interrupted by a player, death underground, cleanup |
| scarecrow, crows, witch and boss | stun rules (2 s, no extension, immunity, death, leaving, snap-back), fence vault and leap cooldown, crow theft and loot recovery, witch minion cap, potion slow and staying behind the frontline, boss announcement, HUD, configured aura buff, instant barricade crush, rewards |
| waves 1-12 | instant kills on every frame: each wave completes exactly once, boss wave 10, alive cap, a player leaving mid-wave, no orphans |
| disconnects | leaving mid-wave ends the match as Abandoned and releases the profile |
| balance smoke | an unprotected, naive Knight bot defending alone survives at least 3 waves (prints the wave it reached) |

The simulation is an approximation (no rigid-body physics, simplified pathfinding), so it
complements the Studio plan below rather than replacing it.

## 2. Debug commands (Studio)

Enabled when `ServerScriptService.Server.DebugConfig.Enabled = true` and the server runs in
Studio (or your UserId is in `AllowedUserIds`). Type in chat:

| Command | Effect |
|---|---|
| `/pf help` | list commands |
| `/pf coins 500` | grant Match Coins |
| `/pf candies 1000` | grant Candies |
| `/pf seeds VoidPumpkin 3` | grant seeds |
| `/pf skip` | end the current phase, or clear the current wave |
| `/pf wave 9` | the next wave will be wave 9 |
| `/pf spawn ZombieMole 3` | spawn enemies 25 studs around you |
| `/pf boss` | spawn the Cursed Harvester |
| `/pf ripen` | ripen every crop |
| `/pf extract` | make this wave an extraction wave (use in Intermission or a wave) |
| `/pf killall` | kill every enemy |
| `/pf stun` | stun yourself |
| `/pf stats` | print matches, enemies, path queue |
| `/pf verbose` | log every Candy transaction |

Set `Enabled = false` before publishing.

## 3. Studio test plan

Use **Test › Clients and Servers** with 1, 2 and 4 players unless noted. "Expected" is what must
happen; anything else is a bug.

### Phase 1: foundation, data, networking

| # | Procedure | Expected |
|---|---|---|
| 1.1 | Play solo | Output: `[DataService] persistence backend: Memory` (Studio) and `[Bootstrap] … server ready (29 services)`. No `[RemoteService] no handler bound` warnings. `ReplicatedStorage.Remotes` has 24 remotes. |
| 1.2 | Check the lobby UI | "Test mode: progress in this server is not saved." Candies 120, record card zeros. |
| 1.3 | Turn on *API Services*, set `DataConfig.UseMockInStudio = false`, publish, play, earn Candies with `/pf candies 50`, stop, play again | Candies persisted (+50). Output shows backend `DataStore`. |
| 1.4 | With API Services on: start a server with player A, then start a second test server with the same account | The second load waits, then gets "Your save data could not be loaded", PLAY is rejected (DataNotLoaded), and no Candies are granted. |
| 1.5 | Exploit: from the command bar of a **client**, run `game.ReplicatedStorage.Remotes.RequestBuySeed:InvokeServer({}, 0/0)` | Returns `{Ok = false, Code = "InvalidPayload"}`. Nothing changes. |
| 1.6 | Exploit: fire `RequestAttack` 200 times in a loop from a client | Only a few are accepted (rate limit). After 40 violations the server logs `[Security] … exceeded violation threshold`. |
| 1.7 | Exploit: `player:SetAttribute("Candies", 999999)` on the client | Only the local display changes. The server balance, purchases and the next ProfileUpdated show the real value. |

### Phase 2: world, lobby, classes, match lifecycle

| # | Procedure | Expected |
|---|---|---|
| 2.1 | Join | You spawn on the lobby plaza with the Knight costume (helmet). |
| 2.2 | Wardrobe prompt → buy Witch with 120 Candies | "Not enough currency." `/pf candies 1000`, buy → Witch unlocked, Equip → costume and stats change (100 HP, speed 17). |
| 2.3 | Equip while queued | allowed. While in a match → rejected (InvalidState). |
| 2.4 | Press PLAY (or the portal prompt) | Queue countdown 8 s, then you are teleported into an arena 1200+ studs away, the HUD shows the wave panel, and Match Coins are 150. |
| 2.5 | Two players queue 3 s apart | Both land in the same match. A 5th queued player gets the next match. |
| 2.6 | 5 groups queue while 4 matches run | "All farms are busy", and the queue retries every 5 s until an arena frees up. |
| 2.7 | Watch the phases | Waiting → Starting (5 s) → Intermission (40 s countdown) → "Wave 1 incoming!" banner → wave. The HUD timer counts down smoothly. |
| 2.8 | Die by jumping off the arena edge during intermission | Respawn after 3 s. During a wave you stay knocked out ("KNOCKED OUT") until WaveComplete. |
| 2.9 | Leave mid-match (close the client) | Other players continue. If you were alone, the match ends ("abandoned") and the arena folder is removed within ~8 s. |

### Phase 3: farming, economy, extraction

| # | Procedure | Expected |
|---|---|---|
| 3.1 | Open the seed shop (G) during intermission | 3 entries, always including Neon Star-Fruit, with prices in multiples of 5. Buy → Candies drop by the price, the pouch shows +1, stock −1 for everyone in the match. |
| 3.2 | Open the shop during a wave | "Closed during waves", purchases are rejected. |
| 3.3 | Two clients buy the last unit at the same time | Exactly one succeeds. The other sees "Sold out!". |
| 3.4 | Select a seed in the pouch and walk to a plot | "Plant …" prompts appear only on empty slots. Plant → a seedling appears, the billboard shows growth %, and the seed count drops. |
| 3.5 | Exploit: invoke `RequestPlant("Plot1", 1, "VoidPumpkin")` without owning one, or from 100 studs away | NotOwned / OutOfRange. Nothing is planted. |
| 3.6 | `/pf ripen`, harvest | "READY!" then harvest → the crop disappears, the chest chip increases, and HarvestUI lists the item and value. A second harvest request for the same uid → NotFound. |
| 3.7 | `/pf extract` during intermission, `/pf skip` the wave | After WaveComplete the Escape Door appears near the north gate with two prompts and EscapeUI (30 s timer, payout, danger preview). |
| 3.8 | Escape from far away using the UI | "Walk to the Escape Door first!". At the door: you return to the lobby, Candies += chest value, and the stats card shows +1 escape. Spamming the button or prompt pays only once. |
| 3.9 | 2 players: A chooses Continue, B does nothing | At the deadline B stays (notified). PREPARATION 30…0 with "DANGER LEVEL I • Zombies x1.50 health". Defenses repaired, Great Pumpkin healed, shop restocked. |
| 3.10 | 2 players: both ignore the door | At the deadline both are escaped and paid, and the match ends ("Everyone escaped"). |
| 3.11 | Continue, then let the Great Pumpkin die (`/pf spawn ZombieFarmer 20`, don't fight) | "FARM LOST" card, the chest is forfeited (HarvestUI: "The harvest was lost"), no Candies, and statistics still count kills and waves. |
| 3.12 | New profile with 0 Candies and 0 seeds (`DataService:Update` from the server command bar) | At match start: "The farm spirits left you 2 Neon Star-Fruit seeds". |

### Phase 4: combat, AI, defenses, waves

| # | Procedure | Expected |
|---|---|---|
| 4.1 | Knight: click at a group | Slash arc, damage numbers on up to 8 enemies in a 150° cone within 10 studs, knockback. Q → Reaping Whirl, 10 s cooldown on the button. |
| 4.2 | Witch: click | A hex bolt flies and explodes. Enemies near the centre take more damage than at the edge (falloff to 40 %). Q → Hex Nova slows enemies (they visibly walk slower). |
| 4.3 | Exploit: fire `RequestAttack(Vector3.new(1e5,0,0), 999999)` and then attacks with lower sequence numbers | The far aim is rejected (violation) and lower sequences are ignored. |
| 4.4 | Build a Wooden Barricade in every gate (B, click, R rotates) | Ghost is green inside the ring and red otherwise. Placing on a plot, a rock or another defense → Blocked. Players walk through barricades, zombies don't. |
| 4.5 | Waves 1–3 with sealed gates | Zombies gather at the barricades and hit them (health on the upgrade prompt drops). An open gate is preferred when it exists. |
| 4.6 | `/pf spawn ZombieMole` with crops planted | The mole digs in (dirt burst), a dirt mound moves underground under the fence/barricades, and it erupts beside a crop and eats it. Hitting it with the scythe while buried does nothing. The Witch staff does half damage. Hit it after it surfaces → it fights you and returns to crops after 6 s without hits. |
| 4.7 | Moles with crops behind rocks | The tunnel routes around rocks (never surfaces inside one). |
| 4.8 | `/pf spawn BlightedScarecrow` behind a barricade line | Red circle telegraph, the scarecrow leaps over the wall, the landing shockwave damages you, and you're stunned 2 s (can't move or attack; "Stunned" chip). A second scarecrow right after can't re-stun during the immunity window. |
| 4.9 | Stun + exploit WalkSpeed on the client | The character is snapped back to the stun position. |
| 4.10 | `/pf spawn PlagueCrow` | Flies above everything, dives on a crop, steals it ("A crow stole …"), and flies to the edge. Shoot it down while it carries a ripe crop → "Recovered a stolen …" and the chest increases. It can't carry a Void Pumpkin (pecks it instead). |
| 4.11 | `/pf spawn Witch` | Keeps distance, retreats when you rush it, throws arcing green potions (the splash slows you, "Slowed" chip), summons 2 sprouts every 12 s, never more than 4 alive. |
| 4.12 | `/pf wave 10`, `/pf skip` intermission | Boss banner, the Cursed Harvester rises (3 s), the boss bar appears with % and aura radius. It crushes barricades on contact, sweeps nearby crops and players, zombies near it move faster, it enrages below 30 % (bar pulses), and the kill adds a Cursed Core to the chest. |
| 4.13 | Sentries | A Pumpkin Sentry shoots the nearest enemy incl. crows, never buried moles. A Hex Lantern pulses and chills. Upgrade with F (coins deducted, level shown). |
| 4.14 | Items | Helmet +40 max HP (bought once). Boots +3 speed. Healing Tonic (H) heals 60, then has a 15 s cooldown, and is rejected at full HP. Repair Kit repairs all defenses. |

### Phase 5: multiplayer, failure and cleanup

| # | Procedure | Expected |
|---|---|---|
| 5.1 | 4 players, wave 20+ with Continue level 2 (`/pf wave 20`) | Server heartbeat stays smooth. `/pf stats` shows at most 45 alive enemies per match and the path queue drains. |
| 5.2 | 2 matches at once (2 groups) | Enemies, crops, chests, shop stock and timers are fully independent. Damage, effects and notifications never cross matches. |
| 5.3 | All players die in a wave | "Everyone was knocked out!", chest forfeited, return to lobby. |
| 5.4 | Kill the server mid-wave (stop) with DataStores enabled | On restart, the profile loads normally after the stale lock (or right away if BindToClose released it). Stats from the interrupted match were committed by PlayerRemoving. |
| 5.5 | Delete `ServerScriptService.Server.Classes.Crop` in a copy and plant | The plant request returns ServerError (logged). The match continues. |
| 5.6 | Cleanup: finish a match and inspect Workspace | `Matches/Match_<id>` is gone and no stray enemy models remain. Within 30 s the orphan sweep would log anything left behind. |
| 5.7 | Long session: run 5 matches back to back | Server memory (Developer Console › Memory) returns to its baseline between matches; no lingering connections (LuaHeap stable). |
| 5.8 | Settings | Toggle Effects off → only telegraphs, damage numbers, hurt flash and projectiles remain. Music toggle persists across rejoin (with DataStores). |
| 5.9 | Mobile emulator | Buttons ≥ 44 px, tap attacks (auto-aim at the nearest enemy in front), ability button, tap-to-place defenses with a Cancel button. |
| 5.10 | Gamepad | R2 attack, Y ability, X/Y door prompts, B closes panels or cancels placement. |
