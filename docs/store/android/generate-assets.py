#!/usr/bin/env python3
"""Regenerate the Google Play icon and feature graphic from Hall-e's brand icon."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SOURCE_ICON = ROOT / "docs" / "assets" / "hall-e.png"
ICON_OUTPUT = HERE / "hall-e-play-icon-512.png"
FEATURE_OUTPUT = HERE / "feature-graphic-1024x500.png"

PALETTE = {
    "deep": (12, 54, 61),
    "green": (13, 93, 87),
    "mint": (89, 222, 199),
    "cream": (248, 243, 222),
    "white": (255, 255, 255),
}


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    path = "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf"
    return ImageFont.truetype(path, size)


def main() -> None:
    icon = Image.open(SOURCE_ICON).convert("RGBA")
    icon.resize((512, 512), Image.Resampling.LANCZOS).save(ICON_OUTPUT, optimize=True)

    width, height = 1024, 500
    image = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(image, "RGBA")

    # A quiet green-to-blue brand field with low-contrast line art. The only
    # product mark is the existing icon; there are no simulated app screens.
    for x in range(width):
        t = x / (width - 1)
        color = tuple(round(PALETTE["deep"][i] * (1 - t) + PALETTE["green"][i] * t) for i in range(3))
        draw.line((x, 0, x, height), fill=color)
    draw.ellipse((760, -250, 1220, 210), outline=(255, 255, 255, 20), width=2)
    draw.ellipse((820, -185, 1130, 125), outline=(89, 222, 199, 36), width=2)
    draw.arc((760, 120, 1150, 510), 195, 345, fill=(255, 255, 255, 23), width=2)

    icon_size = 306
    icon = icon.resize((icon_size, icon_size), Image.Resampling.LANCZOS)
    image.paste(icon, (78, (height - icon_size) // 2), icon)

    draw = ImageDraw.Draw(image)
    x = 438
    draw.text((x, 78), "Hall-e", font=font(76, bold=True), fill=PALETTE["cream"])
    draw.text((x + 2, 183), "Your calendar,", font=font(41, bold=True), fill=PALETTE["white"])
    draw.text((x + 2, 235), "gently organized", font=font(41, bold=True), fill=PALETTE["white"])
    draw.text((x + 3, 323), "AGENDA  ·  PROJECTS  ·  REMINDERS", font=font(19, bold=True), fill=PALETTE["mint"])
    draw.text((x + 3, 371), "A local calendar companion for Android", font=font(20), fill=(225, 238, 232))
    image.save(FEATURE_OUTPUT, format="PNG", optimize=True)

    print(f"Wrote {ICON_OUTPUT} (512×512)")
    print(f"Wrote {FEATURE_OUTPUT} (1024×500)")


if __name__ == "__main__":
    main()
