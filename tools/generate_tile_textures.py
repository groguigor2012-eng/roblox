"""Generate seamless pool-tile PBR maps for the "PoolTile" MaterialVariant.

Outputs 1024x1024 PNGs in assets/textures/ containing an 8 x 8 grid of square
tiles with thin grout lines. Upload them to Roblox and set the MaterialVariant's
StudsPerTile to 8 (=> one tile per stud). The grout is split across the image
borders so the texture tiles seamlessly.

    pip install pillow numpy
    python tools/generate_tile_textures.py
"""

from pathlib import Path

import numpy as np
from PIL import Image

SIZE = 1024
TILES = 8
GROUT = 7  # px of grout between two tiles (~5% of a tile)
BEVEL = 6  # px over which the tile edge rounds down into the grout
SEED = 7

OUT = Path(__file__).resolve().parent.parent / "assets" / "textures"


def tile_distance() -> np.ndarray:
    """Distance (px) from each pixel to the nearest grout line centre."""
    cell = SIZE / TILES
    coords = np.arange(SIZE) + 0.5
    d = np.abs(((coords + cell / 2) % cell) - cell / 2)  # distance to a cell border
    return np.minimum(d[None, :], d[:, None])


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(SEED)
    cell = SIZE // TILES

    dist = tile_distance()
    # 0 in the grout, ramps to 1 over the bevel, 1 on the tile face.
    height = np.clip((dist - GROUT / 2) / BEVEL, 0.0, 1.0)
    height = height * height * (3 - 2 * height)  # smoothstep for a rounded edge

    # Colour: warm off-white glazed tiles, each very slightly different.
    tile_tint = rng.normal(0.0, 2.2, size=(TILES, TILES))
    per_pixel_tint = np.kron(tile_tint, np.ones((cell, cell)))
    tile_rgb = np.array([246.0, 244.0, 237.0])
    grout_rgb = np.array([196.0, 199.0, 192.0])
    noise = rng.normal(0.0, 0.8, size=(SIZE, SIZE))
    color = (
        grout_rgb[None, None, :] * (1 - height[..., None])
        + tile_rgb[None, None, :] * height[..., None]
        + (per_pixel_tint + noise)[..., None] * height[..., None]
    )
    Image.fromarray(np.clip(color, 0, 255).astype(np.uint8), "RGB").save(OUT / "pool_tile_color.png")

    # Normal map (tangent space, OpenGL / +Y up as Roblox expects) from the height field.
    strength = 3.0
    gy, gx = np.gradient(height)
    nx = -gx * strength
    ny = gy * strength  # image rows go down, +Y in tangent space goes up
    nz = np.ones_like(nx)
    length = np.sqrt(nx * nx + ny * ny + nz * nz)
    normal = np.stack([nx, ny, nz], axis=-1) / length[..., None]
    Image.fromarray(((normal * 0.5 + 0.5) * 255).astype(np.uint8), "RGB").save(OUT / "pool_tile_normal.png")

    # Roughness: glossy glaze, matte grout.
    roughness = 0.75 * (1 - height) + 0.12 * height + rng.normal(0, 0.01, size=(SIZE, SIZE))
    Image.fromarray((np.clip(roughness, 0, 1) * 255).astype(np.uint8), "L").save(OUT / "pool_tile_roughness.png")

    print(f"wrote textures to {OUT}")


if __name__ == "__main__":
    main()
