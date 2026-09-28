#!/usr/bin/env python3
"""Apply Sonara's modest desktop corner radius and rebuild the Windows icon.

This is a deterministic asset transform. It edits no artwork and uses no
generated imagery; it only masks the existing desktop mark and exports the ICO
sizes used by Windows.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = ROOT / "Sonara.png"
DEFAULT_MARK = ROOT / "apps" / "sonara" / "assets" / "branding" / "app_mark.png"
DEFAULT_ICON = (
    ROOT / "apps" / "sonara" / "windows" / "runner" / "resources" / "app_icon.ico"
)
ICON_SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)
TILE_SIZE = 1024
TILE_COLOR = (64, 87, 200, 255)  # Sonara indigo: #4057C8
GLYPH_FRACTION = 0.64


def rounded_mask(size: tuple[int, int], radius_fraction: float) -> Image.Image:
    width, height = size
    scale = 4
    radius = round(min(width, height) * radius_fraction * scale)
    mask = Image.new("L", (width * scale, height * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, width * scale - 1, height * scale - 1),
        radius=radius,
        fill=255,
    )
    return mask.resize((width, height), Image.Resampling.LANCZOS)


def build(
    source_path: Path,
    mark_path: Path,
    icon_path: Path,
    radius_fraction: float,
) -> None:
    # Always start from the original transparent wave artwork. Reapplying an
    # alpha mask to an already-rounded export makes edges softer on every build.
    source_image = Image.open(source_path).convert("RGBA")
    content_bounds = source_image.getchannel("A").getbbox()
    if content_bounds is None:
        raise ValueError("Sonara source artwork is empty")
    glyph = source_image.crop(content_bounds)
    glyph.thumbnail(
        (round(TILE_SIZE * GLYPH_FRACTION), round(TILE_SIZE * GLYPH_FRACTION)),
        Image.Resampling.LANCZOS,
    )

    tile_mask = rounded_mask((TILE_SIZE, TILE_SIZE), radius_fraction)
    mark_image = Image.new("RGBA", (TILE_SIZE, TILE_SIZE), TILE_COLOR)
    mark_image.putalpha(tile_mask)
    glyph_position = (
        (TILE_SIZE - glyph.width) // 2,
        (TILE_SIZE - glyph.height) // 2,
    )
    mark_image.alpha_composite(glyph, glyph_position)

    mark_path.parent.mkdir(parents=True, exist_ok=True)
    mark_image.save(mark_path, format="PNG", optimize=True)

    icon_path.parent.mkdir(parents=True, exist_ok=True)
    mark_image.save(
        icon_path,
        format="ICO",
        sizes=[(size, size) for size in ICON_SIZES],
        bitmap_format="png",
    )

    print(f"Desktop icon source: {source_path}")
    print(f"Rounded desktop mark: {mark_path}")
    print(f"Windows icon: {icon_path}")
    print(f"Corner radius: {radius_fraction:.0%}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--mark", type=Path, default=DEFAULT_MARK)
    parser.add_argument("--icon", type=Path, default=DEFAULT_ICON)
    parser.add_argument(
        "--radius",
        type=float,
        default=0.28,
        help="corner radius as a fraction of the shortest edge (default: 0.28)",
    )
    args = parser.parse_args()
    if not 0.02 <= args.radius <= 0.35:
        parser.error("--radius must be between 0.02 and 0.35")
    build(
        args.source.resolve(),
        args.mark.resolve(),
        args.icon.resolve(),
        args.radius,
    )


if __name__ == "__main__":
    main()
