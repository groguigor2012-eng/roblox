#!/bin/sh
# Headless checks for the Poolrooms generator, run with Lune (https://lune-org.github.io).
# Builds every chunk layout and joint outside Roblox and verifies:
#   - no zero-size parts, interiors stay inside their chunk
#   - no two axis-aligned faces share a plane and overlap (z-fighting)
#   - every chunk within 20 of spawn is reachable (no sealed rooms)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
MODS="$HERE/.mods"
rm -rf "$MODS"; mkdir -p "$MODS"
for f in "$HERE"/../src/shared/*.luau; do
  {
    echo 'local roblox = require("@lune/roblox")'
    echo 'local Instance, CFrame, Vector3, Vector2, Color3, Enum, Region3 = roblox.Instance, roblox.CFrame, roblox.Vector3, roblox.Vector2, roblox.Color3, roblox.Enum, roblox.Region3'
    echo 'local Random = require("../random")'
    sed -e 's/require(script.Parent.\([A-Za-z]*\))/require(".\/\1")/' -e 's/^--!strict//' "$f"
  } > "$MODS/$(basename "$f")"
done
cd "$HERE" && lune run geometry_check.luau
