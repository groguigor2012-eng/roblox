# Tame a Pet: architecture

## Boot sequence

`ServerScriptService.ServerBootstrap` runs these steps in order:
1. `Security.Remotes.ensure()` makes sure every remote in `Shared.RemoteNames` exists with the right class.
2. `Shared.ConfigValidator` cross-checks all config modules and prints `[Config]` warnings.
3. `World.MapBuilder.build()` generates the test world if `Workspace.Map` is empty. It also always
   makes sure the spawn, the Compass Merchant and the world bounds exist.
4. `World.ZoneRegistry.init()` resolves each zone to a part in `Workspace.MapZones`, creating any that are missing.
5. Every service's `init(services)` runs. This only wires dependencies, so there are no cross-calls yet.
6. Every service's `start()` runs, in this order:
   `RemoteSecurityService`, `DataService`, `PlayerStateService`, `NotificationService`,
   `EconomyService`, `InventoryService`, `PetService`, `MountService`, `TamingService`,
   `EggSpawnService`, `ItemSpawnService`, `HatchingService`, `EggInteractionService`,
   `CompassService`.

Services reach each other through the `services` table they receive in `init`, never through
`require`, so no module depends on another in a circle. A player can't act until
`PlayerStateService.isReady(player)` is true. That happens only after their profile has loaded,
been migrated and been repaired. Every remote and every ProximityPrompt is gated on it.

The client side mirrors this. `StarterPlayerScripts.ClientBootstrap` loads `Net`, `ClientState`,
`NotificationController`, `HudController`, `CompassController`, `InventoryController`,
`ShopController`, `HatchController` and `MountInputController`, then runs `init` on all of them,
then `start`.

## Who owns what

| State | Owner | Notes |
|---|---|---|
| Profile data | `DataService` (ProfileStore session) | It is only changed through `Data/Transactions` (pure functions with no yields, so each one is atomic). |
| Currency, purchases | `EconomyService` + `Transactions.purchase/quote` | Prices come from `ShopConfig` on the server. |
| Pets, items, compasses | `InventoryService`, `TamingService`, `PetService` | One canonical pet list: `profile.pets[petId]`. |
| Active eggs | `EggSpawnService` (`World/ClaimRegistry`) | `tryClaim` is one check-and-set, so only one player can claim an egg. |
| Item pickups | `ItemSpawnService` (its own `ClaimRegistry`) | Same claim logic as eggs. |
| Compass target | `CompassService` | Navigation only. It never authorises a claim. |
| Mount physics | `MountService` (server network ownership) | `Shared/MountPhysics` is the movement model. `Services/MountStats` holds the one speed formula. |

## Remotes and payload contracts

All request remotes are `RemoteFunction`s that return a **Result**:
`{ ok: boolean, code: string, message: string?, data: any? }`. The codes are listed in
`Shared/RemoteNames.Codes`. Every request goes through `RemoteSecurityService`, which applies:
argument validation, the profile-loaded gate, a per-action rate limit (`GameConfig.RateLimits`),
a per-player transaction lock, and pcall isolation.

| Remote | Direction | Arguments / payload | Server checks |
|---|---|---|---|
| `RequestSync` | C→S RF | none → `data = ProfileView` | loaded, rate limit |
| `Purchase` | C→S RF | `productId: string` | id format, product exists, not already owned, required zone owned, enough money; the server quotes the price |
| `EquipCompass` | C→S RF | `compassId: string` (`""` = unequip) | owned, exists |
| `EquipPet` | C→S RF | `petId: string` (`""` = unequip) | owned, `Tamed`, species known; dismounts if the equipped pet changes |
| `TamePet` | C→S RF | `petId: string` | owned, `Untamed`, required item (from `PetConfig`) is in the inventory; atomic consume + status change |
| `SummonMount` | C→S RF | none | an equipped `Tamed` pet, alive character, cooldown |
| `Dismount` | C→S RF | none | none |
| `MountInput` | C→S UnreliableRemoteEvent | `(forward, turn, vertical: number in [-1,1], jump: boolean)` | finite numbers (values beyond ±1.5 are dropped, smaller overshoot is clamped), rider has a mount, rate limit; input older than `InputStaleSeconds` becomes "no input" |
| `ProfileSync` | S→C RE | `ProfileView` (see below) | sent once per frame at most, after any change |
| `CompassTarget` | S→C RE | `{ eggId, position: Vector3, tier, zoneId, compassId }` or `{ none = true, reason = "NoCompass" \| "NoEggs", compassId? }` | sent only when the target changes |
| `HatchResult` | S→C RE | `{ petId, species, displayName, rarity, eggTier, eggName, oddsText, requiredItem, requiredItemName, coins, itemDropped }` | sent after the pet is saved to the profile |
| `MountState` | S→C RE | `{ mounted = true, petId, species, displayName, speed, canFly, abilities }` or `{ mounted = false, reason }` | |
| `Notify` | S→C RE | `{ kind = "info" \| "success" \| "error" \| "rare" \| "coin", text, rarity? }` | the server drops a repeat of the same message within 1.5 s |

Eggs and item pickups have no remote. Their `ProximityPrompt.Triggered` fires on the server and
the object's id is bound when the server creates the prompt, so the client can't name an object.
The server still checks distance (prompt distance + `DistanceTolerance`), because exploit tools
can fire prompts from anywhere.

## Profile schema (version 1)

```lua
{
  schemaVersion = 1,
  currency = 300,
  compasses = { [compassId] = true },
  equippedCompass = "",            -- "" = none
  pets = { [petId] = {
      id, species, rarity,          -- rarity of the species when it hatched
      eggTier,                      -- the egg it came from (sets its displayed odds)
      status = "Untamed" | "Tamed",
      acquiredAt, tamedAt,          -- os.time(); tamedAt = 0 until tamed
  } },
  items = { [itemId] = quantity }, -- quantities are always whole numbers > 0
  equippedPetId = "",              -- must point to a Tamed pet
  speedUpgradeLevel = 0,
  unlockedZones = { Meadow = true, Forest = true, Canyon = true },
  stats = { eggsHatched, itemsCollected, petsTamed, coinsEarned },
  flags = { studioKitGranted? },
  createdAt, lastJoinAt,
}
```

Each player has one profile, saved in `GameConfig.Data.StoreName` under the key
`"Player_<UserId>"`.

**Loading a profile.** This happens in `DataService.onPlayerAdded`:
1. `StartSessionAsync` loads the profile with ProfileStore's session lock. The load is cancelled
   if the player leaves.
2. If loading fails, the player is **kicked**. The server never falls back to a blank profile,
   because saving it would overwrite their real data.
3. `Migrations.run` upgrades older profiles. A profile saved by a *newer* server version is
   released untouched and the player is asked to rejoin.
4. `Reconcile` fills in any missing fields.
5. `ProfileSchema.sanitize` repairs impossible values, such as negative coins, invalid pet
   statuses, or an equipped pet that is untamed or no longer exists. Unknown species are kept
   but hidden.

**Saving and releasing.** ProfileStore saves automatically every few minutes. It also saves and
releases the session when the player leaves (`EndSession`) and when the server shuts down
(`BindToClose`). If the player joins another server, that server takes the session and this one
kicks the player.

**Changing the schema.**
1. Increase `ProfileSchema.CURRENT_VERSION`.
2. Add a `Migrations.Steps[oldVersion]` entry.
3. Add a test in `tests/specs/data_spec.luau`.

## Odds definition

A pet's displayed odds are its chance from one egg of the tier it hatched from:
`weight / sum(weights)` of that egg's pool. This is shown as "1 in N" with N = sum / weight.
- Whole numbers display exactly: "1 in 1,000".
- Other small values keep up to two decimals: "1 in 2.5".
- Large values that aren't whole numbers show with a tilde: "~1 in 1,334".

The odds come from `EggConfig` on the server and are included in `ProfileSync`, `HatchResult`
and the server-built billboards, so no client can change what other players see. Odds depend on
the egg tier, never on the zone the egg spawned in. Zone weights only decide which egg tier
appears.

## Mounts and physics

**Rig.** `World/MountFactory` builds each mount from these parts:
- an invisible Ball collider (`Root`), which is the assembly root
- the pet model, welded on, massless and non-colliding
- a `Seat` placed at the pet's `Saddle` attachment
- `LinearVelocity` (Plane mode on the ground, Vector mode in the air) and `AlignOrientation`,
  which keeps the mount upright and makes it bank and pitch in flight

**Network ownership.** The server owns the mount. `SetNetworkOwner(nil)` is called once the
rider is seated and is re-applied every step. Because of this, mount controls respond one round
trip of ping late. When the rider dismounts, the character is handed back to its player.

**Speed.** One formula decides how fast a mount moves:
`min(baseSpeed × tierMultiplier × (1 + level × UpgradeBonusPerLevel), MaxMountSpeed)` in studs/s.
It lives in `Services/MountStats`, and the UI only shows values the server computed with it.

**Server checks while riding.**
- If the server stops receiving the rider's input, the mount stops.
- Flying is only possible for pets with the `Flight` ability.
- Flying mounts are forced to land in zones where `allowFlight = false`, and can't climb above
  `MaxFlightAltitude` or the world ceiling.
- Measured speed is clamped to the cap × `SpeedTolerance`.
- Network ownership is re-claimed if it changes.

**Cleanup.** The mount is removed when the player dismounts or dies, the character is reset or
removed, the player leaves, the equipped pet changes, the rider leaves the seat, or the mount
falls below the world. A sweep every 10 seconds also destroys any mount model that has no live
record.

## Edge cases and where they're handled

| Case | Handling |
|---|---|
| The egg you're tracking despawns or is claimed | `EggSpawnService.EggRemoved` makes `CompassService` immediately re-target everyone who was tracking it. The needle shows an idle state when no eggs are left. |
| Two players open the same egg | `ClaimRegistry.tryClaim` (no yields between check and set): the second player is told "Someone else got to that egg first!" |
| Hatching an egg that no longer exists | `getActive` returns nil → "That egg is gone." |
| Disconnecting during the hatch | The pet is saved before `HatchResult` is sent, and the animation is client-only. On rejoin it's in the inventory. |
| Taming without the item / taming twice / two requests for one item / someone else's pet | `Transactions.tamePet` checks everything before changing anything, and the player's transaction lock serialises requests. Covered by tests. |
| A pickup vanishes before collection | Its claim fails → "That item is gone." |
| Not enough currency | `Transactions.purchase` changes nothing and returns `InsufficientFunds` with how much is missing. |
| Spamming a remote | Per-action rate limit. The client never shows a notification for `RateLimited`, and the server's log for it is throttled. |
| A profile fails to load or save | The player is kicked (no blank profile). ProfileStore retries saves and reports errors through `OnError` / `OnCriticalToggle`. |
| Character reset while riding | `CharacterRemoving` / `Died` → dismount. |
| Flying where it isn't allowed | Forced landing. Land mounts can never enter flight mode. |
| Malformed or huge mount input | NaN, infinity, non-numbers and values beyond ±1.5 are dropped. Small overshoot is clamped. |
| Orphaned mounts | Cleaned up on leave, plus the 10-second sweep. |
| A missing model, zone or item spawn zone | A warning names the exact path to fix. A generated placeholder is used, or the spawn is skipped if `AllowPlaceholders` is false. |
| The inventory changes while its UI is open | The panel rebuilds whenever `ProfileChanged` fires. Buttons are destroyed with their connections. |

## What has been verified (and how)

- **Type checking:** `luau-lsp analyze` 1.70.1 with the Roblox definitions and the Rojo
  sourcemap, over all of `src` (ProfileStore excluded): **0 errors**.
- **Unit tests:** `lune run tests/run.luau`, **42/42 passing**. I also deliberately broke two
  rules (item consumption and the speed cap) to make sure the tests catch them.
- **Build:** `rojo build` succeeds. I opened the built `.rbxl` with Lune and checked that the
  instance tree matches the target structure (folders, all 13 remotes with their classes, the
  ScreenGuis, scripts and modules).
- **Not verified:** nothing has been run inside Roblox Studio or a live server. Gameplay feel,
  physics tuning, UI layout on real devices and DataStore behaviour still need a Studio playtest.

## Manual Studio steps and known limitations

- **Live data in Studio.** Only if you want it: enable Studio API access and set
  `GameConfig.Data.UseLiveDataStoreInStudio = true`.
- **Placeholder art.** Pets, eggs and items are built from simple parts. To replace them, drop in
  models (see the README). Icons in the UI are coloured initials, not images.
- **Mount input latency.** Because the server owns the mount, input takes one network round
  trip. The client-ownership option in `MountConfig.NetworkOwnership` is documented but not
  implemented. Only `"Server"` exists.
- **Mount handling.** Turning, acceleration and collider sizes are tuned by reasoning, not by
  playtesting. Adjust them in `MountConfig`.
- **Locked zones** have no physical barrier. A pass is needed to hatch eggs, collect items or
  track eggs there, and the compass ignores eggs in zones you haven't unlocked.
- **No developer products.** There are no Robux purchases. All currency is earned in-game.
