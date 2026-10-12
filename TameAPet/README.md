# Tame a Pet

An open-world exploration, egg-hatching, taming and mount game for Roblox. You explore, follow
a compass to hidden eggs, hatch random animals, hunt for the rare item each one needs to be
tamed, then ride it on land or fly it through the sky.

All server code is server-authoritative. The client only sends requests (a pet id, a product
id, movement intent). The server decides prices, RNG, rewards, taming and physics.

## The gameplay loop

1. **Join.** Your profile loads, or a new one is created with 300 coins (`GameConfig.StartingCurrency`).
2. **Buy a compass.** Press **B** or talk to the Compass Merchant next to spawn. The Wooden Compass costs 100.
3. **Track an egg.** The compass needle at the bottom of the screen points to the nearest egg. The
   distance updates live, and the dial glows brighter as you get closer.
4. **Hatch it.** Hold **E** on the egg. The server claims the egg (one winner only), rolls the pet,
   saves it as **Untamed**, and you see the hatch reveal with the pet's rarity and odds.
5. **Find its taming item.** Items are hidden around their zones, and sometimes one drops next to
   the egg you just hatched. Hold **E** to collect it.
6. **Tame it.** Open the inventory (**G**) → Pets → select the pet → **Tame**. This uses up exactly
   one item.
7. **Equip and ride.** In the inventory choose **Equip**, then press **R** or the **Ride** button.
   - Land mounts: **WASD** to steer, **Space** to jump (Ember Wolf and Shadow Fox can double-jump).
   - Flying mounts: **Space** to take off and climb, **LeftControl**/**Q** to descend and land.
   - Press **R** again to dismount.
8. **Progress.** Rarer zones (Moonlit Lake, Storm Peaks) are unlocked in the shop. Better compasses
   and Saddle Upgrades (permanent mount speed) are also sold there.

Touch devices use the thumbstick to steer, plus on-screen **Up**/**Down**, **Ride**/**Dismount**,
**Inventory** and **Shop** buttons. Gamepads use the left stick, **A**/**B** for up/down and **Y**
to ride.

## Setup

Requirements:
- **[Rojo](https://rojo.space) 7.4+** (tested with 7.4.4), plus the Rojo Studio plugin if you want live sync.
- **ProfileStore** is already included at `src/server/Packages/ProfileStore.luau`
  (MadStudioRoblox/ProfileStore, commit `45c9847`, Apache-2.0, licence alongside it). There is nothing to install.
- Optional: **[Lune](https://lune-org.github.io) 0.8+** to run the headless tests.

```sh
cd TameAPet
rojo build default.project.json -o TameAPet.rbxl   # open the place file in Studio
# or live-sync into an open place:
rojo serve default.project.json
```

Then in Studio:
1. **Game Settings → Security → Enable Studio Access to API Services**. Only needed if you set
   `GameConfig.Data.UseLiveDataStoreInStudio = true`. By default Studio uses ProfileStore's mock
   store, so playtests never touch real player data. When published, the live DataStore is used.
2. Press **Play**. The server generates the test world, spawns eggs and items, and you spawn next
   to the Compass Merchant.

**Studio test kit.** New mock profiles in Studio also get an untamed Storm Griffin and one Storm
Core, so you can test taming and flight straight away. Turn this off with
`GameConfig.Debug.StudioStarterKit.Enabled = false`. It never applies on live servers.

No UI, remotes or map has to be built by hand. Remotes and ScreenGuis are created at runtime if a
place doesn't have them, and the map is generated whenever `Workspace.Map` is empty.

## Project layout

```
TameAPet/
  default.project.json        Rojo tree (maps to the Studio hierarchy below)
  src/shared/                 ReplicatedStorage.Shared   pure logic + placeholder art builders
  src/config/                 ReplicatedStorage.Config   all tuning/config (pets, eggs, items, zones, shop...)
  src/server/ServerBootstrap  ServerScriptService        boot order: remotes → config check → world → services
  src/server/Services/        ServerScriptService.Services  gameplay services
  src/server/Data/            ServerScriptService.Data   schema, migrations, transactions, view, ProfileStore adapter
  src/server/Security/        ServerScriptService.Security  remotes, validation, rate limits, locks
  src/server/World/           ServerScriptService.World  map builder, zones, spawn finder, registries, mount rig
  src/server/Packages/        ServerScriptService.Packages  ProfileStore (vendored)
  src/client/                 StarterPlayerScripts       ClientBootstrap + Controllers/UIControllers/InputControllers
  tests/                      headless Lune tests for the pure modules
  docs/ARCHITECTURE.md        systems, remote payload contracts, data schema, security model
```

## Extending

| To add… | Edit | Then |
|---|---|---|
| A pet | `PetConfig.Species` (rarity, `requiredItem`, mountType, speed, abilities, look) | add it to an egg pool in `EggConfig`; optionally add a model to `ServerStorage.PetModels/<id>` |
| A taming item | `ItemConfig.Items` (rarity, shape/colour, spawn zones and rates) | optionally add `ServerStorage.ItemModels/<id>` |
| An egg tier / rarity | `RarityConfig` + `EggConfig.Tiers` | reference it in zone `eggs.weights` |
| A zone | `ZoneConfig.Zones` (region, egg weights, unlock, flight) | optional shop `ZoneUnlock` product; optionally place a part named after the zone in `Workspace.MapZones` |
| A compass | `CompassConfig.Compasses` | add a `Compass` product to `ShopConfig` |
| Real art | models with a `PrimaryPart` in `ServerStorage.{PetModels,MountModels,EggModels,ItemModels}`; give pet models a `Saddle` attachment for the rider | previews: `ReplicatedStorage.UIAssets.PetPreviews` |

At boot, `ConfigValidator` cross-checks every reference and prints a clear `[Config]` warning for
anything wrong.

## Tests

```sh
cd TameAPet && lune run tests/run.luau   # or tests/run.sh
```

There are 42 tests. They cover the weighted RNG and its distribution, exact odds text, config
integrity, profile migration and repair, and every transaction rule:
- taming uses up exactly one item, a pet can't be tamed twice, and one item can't tame two pets
- you can't tame a pet you don't own
- buying with too little money fails and leaves everything unchanged
- zone unlocks must be bought in order, speed upgrade prices rise per level, and the pet and stack limits hold

They also cover the mount physics: the speed cap, land mounts never flying, jump and double-jump,
take-off and the altitude cap, forced landing, and rejecting malformed input. Finally, the rate
limiter and argument validators. The checks I used while building are listed in
`docs/ARCHITECTURE.md`.
