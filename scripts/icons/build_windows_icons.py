#!/usr/bin/env python3

import argparse
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw


ICON_SIZES = tuple((size, size) for size in (16, 24, 32, 48, 64, 128, 256))
STATUS_COLORS = {
    "playing": "#39C878",
    "pausing": "#F3B43F",
    "locked": "#7D8491",
}


def load_app_icon(source: Path) -> Image.Image:
    image = Image.open(source)
    sizes = image.info.get("sizes", [(256, 256)])
    best = max(sizes, key=lambda size: size[0] * size[1] * (size[2] if len(size) > 2 else 1) ** 2)
    scale = best[2] if len(best) > 2 else 1
    image.size = (best[0] * scale, best[1] * scale)
    return image.convert("RGBA").resize((1024, 1024), Image.Resampling.LANCZOS)


def status_variant(source: Image.Image, color: str) -> Image.Image:
    image = source.copy()
    draw = ImageDraw.Draw(image)
    center = (842, 842)
    draw.ellipse((724, 724, 960, 960), fill="#FFFDF5", outline="#181714", width=22)
    draw.ellipse((762, 762, 922, 922), fill=color)
    return image


def write_ico(image: Image.Image, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination, format="ICO", sizes=ICON_SIZES, bitmap_format="png")


def write_png(image: Image.Image, destination: Path, size: int) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    resized = image.resize((size, size), Image.Resampling.LANCZOS)
    resized.save(destination, format="PNG", optimize=True)


def generated_assets(repository: Path, output_root: Path) -> list[tuple[Path, Path]]:
    source = load_app_icon(repository / "lumen.icns")
    icons = output_root / "src_assets/common/assets/icons"
    assets = [
        (output_root / "lumen.ico", source),
        (icons / "lumen.ico", source),
    ]

    for state, color in STATUS_COLORS.items():
        assets.append((icons / f"lumen-{state}.ico", status_variant(source, color)))

    for destination, image in assets:
        write_ico(image, destination)

    write_png(source, icons / "logo-lumen-16.png", 16)
    for state, color in STATUS_COLORS.items():
        write_png(status_variant(source, color), icons / f"lumen-{state}-16.png", 16)

    relative_paths = [destination.relative_to(output_root) for destination, _ in assets]
    relative_paths.extend(
        [Path("src_assets/common/assets/icons/logo-lumen-16.png")]
        + [Path(f"src_assets/common/assets/icons/lumen-{state}-16.png") for state in STATUS_COLORS]
    )
    return [(output_root / path, repository / path) for path in relative_paths]


def main() -> int:
    parser = argparse.ArgumentParser(description="Build Windows and tray icons from the Lumen app icon.")
    parser.add_argument("--check", action="store_true", help="Verify committed assets without modifying them.")
    arguments = parser.parse_args()

    repository = Path(__file__).resolve().parents[2]
    if not (repository / "lumen.icns").is_file():
        raise SystemExit("generated lumen.icns was not found at the repository root")

    if arguments.check:
        with tempfile.TemporaryDirectory() as temporary_directory:
            comparisons = generated_assets(repository, Path(temporary_directory))
            stale = [target for generated, target in comparisons if not target.exists() or generated.read_bytes() != target.read_bytes()]
        if stale:
            print("stale generated icon assets:")
            for path in stale:
                print(f"  {path.relative_to(repository)}")
            return 1
        print("Windows and tray icons match the Lumen app icon")
        return 0

    comparisons = generated_assets(repository, repository)
    for generated, target in comparisons:
        if generated != target:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(generated, target)
    print("Generated Windows and tray icons from the Lumen app icon")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
