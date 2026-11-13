#!/usr/bin/env python3
"""Extract supplied logo tiles without recoloring them (requires Pillow)."""
from collections import deque
from pathlib import Path

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Sources/CruiseControl/BrandIcons"


def extract(source, destination):
    image = Image.open(source).convert("RGBA")
    width, height = image.size
    pixels = image.load()
    # The backdrop and labels are neutral; the tile perimeter is saturated.
    background = set()
    queue = deque(
        [(x, y) for x in range(width) for y in (0, height - 1)]
        + [(x, y) for y in range(height) for x in (0, width - 1)]
    )
    while queue:
        x, y = queue.popleft()
        if (x, y) in background:
            continue
        rgb = pixels[x, y][:3]
        if max(rgb) - min(rgb) > 24 and max(rgb) > 35:
            continue
        background.add((x, y))
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if 0 <= nx < width and 0 <= ny < height and (nx, ny) not in background:
                queue.append((nx, ny))
    for x, y in background:
        pixels[x, y] = (0, 0, 0, 0)
    remaining = {
        (x, y) for y in range(height) for x in range(width)
        if pixels[x, y][3] != 0
    }
    components = []
    while remaining:
        seed = remaining.pop()
        component = {seed}
        queue = deque([seed])
        while queue:
            x, y = queue.popleft()
            for point in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if point in remaining:
                    remaining.remove(point)
                    component.add(point)
                    queue.append(point)
        components.append(component)
    if not components:
        raise ValueError(f"No logo found: {source}")
    tile = max(components, key=len)
    for component in components:
        if component is not tile:
            for x, y in component:
                pixels[x, y] = (0, 0, 0, 0)
    bounds = image.getbbox()
    if bounds is None:
        raise ValueError(f"No logo found: {source}")
    image = image.crop(bounds)
    image.putalpha(image.getchannel("A").filter(ImageFilter.GaussianBlur(0.35)))
    # Keep a transparent margin so no rounded edge touches the image boundary.
    size = max(image.size) + 4
    canvas = Image.new("RGBA", (size, size))
    canvas.paste(image, ((size - image.width) // 2, (size - image.height) // 2))
    canvas.save(destination)
    assert canvas.getpixel((0, 0))[3] == 0
    assert canvas.getpixel((size // 2, size // 2))[3] == 255
    print(f"{destination.relative_to(ROOT)}: {canvas.size}, transparent corners")


if __name__ == "__main__":
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for theme in ("red", "yellow", "blue", "green"):
        folder = ROOT / "marketing/logos" / theme
        extract(folder / f"{theme[0]}1.jpg", OUTPUT / f"{theme}-cruise.png")
        extract(folder / "rest.png", OUTPUT / f"{theme}-rest.png")
