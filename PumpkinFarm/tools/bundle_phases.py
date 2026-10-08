#!/usr/bin/env python3
"""Writes docs/phase<N>/PHASE<N>_SOURCE.md: the complete source of every file a phase
introduces (or changes), in one document, each file under its exact Studio path and
instance class.

Run from anywhere: python3 PumpkinFarm/tools/bundle_phases.py
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# (section title, [paths relative to PumpkinFarm/])
PHASE1 = [
    ("Project", ["default.project.json"]),
    ("Shared: constants", [f"src/shared/Constants/{n}.luau" for n in
        ["MatchState", "LifeState", "ResultCode", "Attributes", "CollisionGroup", "CurrencyId"]]),
    ("Shared: types and data", ["src/shared/Types/Types.luau", "src/shared/Data/Rarity.luau", "src/shared/Data/Palette.luau"]),
    ("Shared: utilities", [f"src/shared/Utilities/{n}.luau" for n in
        ["TableUtil", "Validate", "Result", "Clock", "MathUtil", "Format", "WeightedRandom"]]),
    ("Shared: classes (Janitor, Signal, StateMachine, TokenBucket)", [f"src/shared/Classes/{n}.luau" for n in
        ["Janitor", "Signal", "StateMachine", "TokenBucket"]]),
    ("Shared: configuration", [f"src/shared/Config/{n}.luau" for n in
        ["NetworkConfig", "CropConfig", "SeedConfig", "EnemyConfig", "WaveConfig", "ClassConfig", "WeaponConfig",
         "DefenseConfig", "EconomyConfig", "StatusEffectConfig", "MatchConfig", "DifficultyConfig", "AudioConfig"]]),
    ("Server: bootstrap", ["src/server/Bootstrap.server.luau", "src/server/Registry.luau"]),
    ("Server: networking", ["src/server/Services/RemoteService.luau", "src/server/Systems/RemoteRateLimiter.luau"]),
    ("Server: data", [f"src/server/Data/{n}.luau" for n in
        ["DataConfig", "ProfileTemplate", "Migrations", "SessionLockedStore", "ProfileServiceWrapper"]]
        + ["src/server/Services/DataService.luau"]),
    ("Server: currencies", [f"src/server/Services/{n}.luau" for n in ["CandyService", "MatchCoinService", "CurrencyService"]]),
    ("Server: players", ["src/server/Classes/PlayerSession.luau", "src/server/Services/PlayerService.luau"]),
    ("Server: match state machine", ["src/server/Classes/Match.luau", "src/server/Services/MatchService.luau"]),
    ("Client: bootstrap and modules", ["src/client/ClientBootstrap.client.luau"]
        + [f"src/client/Modules/{n}.luau" for n in ["ControllerRegistry", "Net", "ClientState"]]),
]

PHASE2 = [
    ("Updated Phase 1 files", [
        "src/shared/Constants/ResultCode.luau", "src/shared/Constants/Attributes.luau",
        "src/shared/Config/MatchConfig.luau", "src/shared/Config/EconomyConfig.luau",
        "src/server/Services/MatchService.luau"]),
    ("Lobby, arena and match lifecycle", [
        "src/server/Services/LobbyService.luau", "src/server/Services/CleanupService.luau",
        "src/server/Classes/FarmCore.luau", "src/server/Systems/MapBuilder.luau"]),
    ("Seeds and the randomized Seed Shop", [
        "src/server/Services/SeedService.luau", "src/server/Classes/SeedShop.luau",
        "src/server/Services/SeedShopService.luau"]),
    ("Farm plots and crops", ["src/server/Classes/Crop.luau", "src/server/Services/CropService.luau"]),
    ("Harvest Chest and rewards", [
        "src/server/Classes/HarvestChest.luau", "src/server/Services/HarvestChestService.luau",
        "src/server/Services/RewardService.luau"]),
    ("Escape Door, escape and continue", ["src/server/Classes/EscapeDoor.luau", "src/server/Services/EscapeService.luau"]),
    ("Defense foundation (barricades, sentries, accessories, utilities)", [
        "src/server/Classes/Defense.luau", "src/server/Classes/Barricade.luau", "src/server/Classes/Sentry.luau",
        "src/server/Services/BarricadeService.luau", "src/server/Services/SentryService.luau",
        "src/server/Services/DefenseService.luau"]),
    ("Procedural models (stage-aware crop visuals, chest, door, defenses)", ["src/server/Systems/ModelFactory.luau"]),
    ("Client UI", [f"src/client/Modules/{n}.luau" for n in ["UIKit", "Panels"]]
        + [f"src/client/Controllers/{n}.luau" for n in [
            "NotificationController", "HUDController", "WaveUIController", "LobbyController", "SeedShopController",
            "CropController", "HarvestChestController", "DefenseShopController", "EscapeController"]]),
]

PHASES = {1: PHASE1, 2: PHASE2}


def studio_path(rel):
    if rel == "default.project.json":
        return "Rojo project file (not an Instance)", "-"
    mapping = [("src/shared/", "ReplicatedStorage.Shared."), ("src/server/", "ServerScriptService.Server."),
               ("src/client/", "StarterPlayer.StarterPlayerScripts.Client.")]
    for prefix, target in mapping:
        if rel.startswith(prefix):
            name = rel[len(prefix):]
            cls = "ModuleScript"
            if name.endswith(".server.luau"):
                cls, name = "Script", name[: -len(".server.luau")]
            elif name.endswith(".client.luau"):
                cls, name = "LocalScript", name[: -len(".client.luau")]
            else:
                name = name[: -len(".luau")]
            return target + name.replace("/", "."), cls
    raise ValueError(rel)


def bundle(phase, sections):
    out = os.path.join(ROOT, "docs", f"phase{phase}", f"PHASE{phase}_SOURCE.md")
    parts, index, total_lines, count = [], [], 0, 0
    for title, files in sections:
        anchor = title.lower().replace(":", "").replace("(", "").replace(")", "").replace(",", "").replace(" ", "-")
        index.append(f"- [{title}](#{anchor})")
        parts.append(f"\n## {title}\n")
        for rel in files:
            with open(os.path.join(ROOT, rel), encoding="utf-8") as handle:
                source = handle.read().rstrip("\n")
            path, cls = studio_path(rel)
            lang = "json" if rel.endswith(".json") else "lua"
            lines = source.count("\n") + 1
            total_lines += lines
            count += 1
            parts.append(f"\n### `{path}`\n\n{cls} · `PumpkinFarm/{rel}` · {lines} lines\n\n```{lang}\n{source}\n```\n")
    header = (
        f"# Phase {phase}: complete source\n\n"
        "Generated by `tools/bundle_phases.py` from the repository; do not edit by hand. "
        f"{count} files, {total_lines} lines. The architecture and checklists are in "
        f"[PHASE{phase}.md](PHASE{phase}.md).\n\n"
        "Each heading is the exact Studio path. Create a ModuleScript (or the Script / LocalScript "
        "shown) with that name and paste the block, or skip all of this and open the built place file.\n\n"
        + "\n".join(index) + "\n"
    )
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as handle:
        handle.write(header + "".join(parts))
    print(f"wrote {os.path.relpath(out, ROOT)}: {count} files, {total_lines} lines")


def main():
    for phase, sections in PHASES.items():
        bundle(phase, sections)


if __name__ == "__main__":
    main()
