#!/usr/bin/env python3
"""Render the Celestia theme assets.

Outputs:
  <refind>/      rEFInd theme: background, selection tiles, OS/tool icons, font, theme.conf
  <grub>/        GRUB theme for the USB stick menu (fonts are added by make-theme.sh)
  <calamares>/   installer branding images
  <wallpapers>/  default wallpaper for new users

Inputs: the caelestia wallpaper, the caelestia logo rendered to PNG, a monospace TTF
and theme/palette.env.
"""

import argparse
import math
import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

SS = 4  # supersampling factor for anti-aliased shapes


def load_palette(path: Path) -> dict[str, str]:
    palette = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            palette[key.strip()] = value.strip()
    return palette


def rgba(hex_colour: str, alpha: int = 255) -> tuple[int, int, int, int]:
    h = hex_colour.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), alpha


def cover(img: Image.Image, w: int, h: int) -> Image.Image:
    scale = max(w / img.width, h / img.height)
    img = img.resize((math.ceil(img.width * scale), math.ceil(img.height * scale)), Image.LANCZOS)
    left, top = (img.width - w) // 2, (img.height - h) // 2
    return img.crop((left, top, left + w, top + h))


def backdrop(wall: Image.Image, w: int, h: int, blur: float, dim: int, colour: str) -> Image.Image:
    """Wallpaper scaled to cover, blurred and dimmed towards the background colour."""
    img = cover(wall.convert("RGB"), w, h)
    if blur:
        img = img.filter(ImageFilter.GaussianBlur(blur))
    img = img.convert("RGBA")
    return Image.alpha_composite(img, Image.new("RGBA", img.size, rgba(colour, dim)))


def rounded(w: int, h: int, radius: int, fill, outline=None, width: int = 0) -> Image.Image:
    img = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle(
        (0, 0, w * SS - 1, h * SS - 1), radius * SS, fill=fill, outline=outline, width=width * SS
    )
    return img.resize((w, h), Image.LANCZOS)


def paste_center(base: Image.Image, top: Image.Image) -> Image.Image:
    out = base.copy()
    out.alpha_composite(top, ((base.width - top.width) // 2, (base.height - top.height) // 2))
    return out


# ------------------------------------------------------------------ icons


def card(size: int, p) -> Image.Image:
    """Translucent tile behind every OS icon; the selection tile shows through it."""
    return rounded(size, size, size // 4, rgba(p["ON_SURFACE"], 14), rgba(p["ON_SURFACE"], 28), 2)


def windows_glyph(size: int, colour) -> Image.Image:
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    gap = s // 14
    half = (s - gap) // 2
    r = s // 22
    for x in (0, half + gap):
        for y in (0, half + gap):
            d.rounded_rectangle((x, y, x + half, y + half), r, fill=colour)
    return img.resize((size, size), Image.LANCZOS)


def tool_glyph(kind: str, size: int, colour) -> Image.Image:
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    w = max(SS * 2, s // 12)
    m = s // 5
    box = (m, m, s - m, s - m)
    if kind == "shutdown":
        d.arc(box, 300, 240, fill=colour, width=w)
        d.line((s // 2, m - w // 2, s // 2, s // 2), fill=colour, width=w)
    elif kind == "reset":
        d.arc(box, 40, 330, fill=colour, width=w)
        tip = (s - m, s // 2 - s // 9)
        d.polygon([(tip[0] - s // 7, tip[1] - s // 10), (tip[0] + s // 12, tip[1] - s // 10), (tip[0], tip[1] + s // 9)],
                  fill=colour)
    elif kind == "firmware":
        inner = (m + s // 10, m + s // 10, s - m - s // 10, s - m - s // 10)
        d.rounded_rectangle(inner, s // 16, outline=colour, width=w)
        for i in range(3):
            pos = inner[0] + (inner[2] - inner[0]) * (i + 1) // 4
            d.line((pos, m - s // 20, pos, inner[1]), fill=colour, width=w // 2)
            d.line((pos, inner[3], pos, s - m + s // 20), fill=colour, width=w // 2)
            d.line((m - s // 20, pos, inner[0], pos), fill=colour, width=w // 2)
            d.line((inner[2], pos, s - m + s // 20, pos), fill=colour, width=w // 2)
    return img.resize((size, size), Image.LANCZOS)


# ------------------------------------------------------------------ rEFInd


def font_strip(ttf: Path, px: int, colour) -> Image.Image:
    """rEFInd bitmap font: ASCII 32..126 plus a glyph for unknown characters, equal cells."""
    font = ImageFont.truetype(str(ttf), px)
    chars = [chr(c) for c in range(32, 127)] + ["?"]
    cell = math.ceil(font.getlength("M"))
    ascent, descent = font.getmetrics()
    img = Image.new("RGBA", (cell * len(chars), ascent + descent), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for i, ch in enumerate(chars):
        d.text((i * cell, 0), ch, font=font, fill=colour)
    return img


def make_refind(out: Path, wall: Image.Image, logo: Image.Image, ttf: Path, p, width: int, height: int) -> None:
    icons = out / "icons"
    icons.mkdir(parents=True, exist_ok=True)

    big, small = 192, 48
    backdrop(wall, width, height, blur=18, dim=150, colour=p["BACKGROUND"]).convert("RGB").save(out / "background.png")

    sel_big = round(big * 1.125)
    rounded(sel_big, sel_big, sel_big // 4, rgba(p["PRIMARY"], 60), rgba(p["PRIMARY"], 200), 3).save(out / "selection_big.png")
    sel_small = round(small * 1.33)
    rounded(sel_small, sel_small, sel_small // 3, rgba(p["PRIMARY"], 70), rgba(p["PRIMARY"], 200), 2).save(out / "selection_small.png")

    tile = card(big, p)
    paste_center(tile, windows_glyph(big * 44 // 100, rgba(p["PRIMARY"]))).save(icons / "os_windows.png")
    logo_px = big * 58 // 100
    paste_center(tile, logo.resize((logo_px, logo_px), Image.LANCZOS)).save(icons / "os_celestia.png")

    small_tile = rounded(small, small, small // 3, rgba(p["ON_SURFACE"], 14))
    for kind, name in (("shutdown", "func_shutdown"), ("reset", "func_reset"), ("firmware", "func_firmware")):
        paste_center(small_tile, tool_glyph(kind, small * 60 // 100, rgba(p["ON_SURFACE_VARIANT"]))).save(icons / f"{name}.png")

    font_strip(ttf, 28, rgba(p["ON_SURFACE"])).save(out / "font.png")

    (out / "theme.conf").write_text(
        "# Celestia theme for rEFInd, generated by scripts/make_theme.py\n"
        "icons_dir themes/celestia/icons\n"
        "banner themes/celestia/background.png\n"
        "banner_scale fillscreen\n"
        "selection_big themes/celestia/selection_big.png\n"
        "selection_small themes/celestia/selection_small.png\n"
        f"big_icon_size {big}\n"
        f"small_icon_size {small}\n"
        "font themes/celestia/font.png\n"
    )


# ------------------------------------------------------------------ GRUB


def nine_slice(out: Path, prefix: str, radius: int, fill, outline=None, width: int = 0) -> None:
    """GRUB pixmap styles are 9 tiles: <prefix>_{nw,n,ne,w,c,e,sw,s,se}.png"""
    size = radius * 3
    img = rounded(size, size, radius, fill, outline, width)
    names = (("nw", "n", "ne"), ("w", "c", "e"), ("sw", "s", "se"))
    for row in range(3):
        for col in range(3):
            box = (col * radius, row * radius, (col + 1) * radius, (row + 1) * radius)
            img.crop(box).save(out / f"{prefix}_{names[row][col]}.png")


def make_grub(out: Path, wall: Image.Image, logo: Image.Image, p) -> None:
    out.mkdir(parents=True, exist_ok=True)
    bg = backdrop(wall, 1920, 1080, blur=14, dim=165, colour=p["BACKGROUND"])
    logo_px = 150
    bg.alpha_composite(logo.resize((logo_px, logo_px), Image.LANCZOS), ((1920 - logo_px) // 2, 250))
    bg.convert("RGB").save(out / "background.png")

    nine_slice(out, "select", 14, rgba(p["PRIMARY"], 60), rgba(p["PRIMARY"], 200), 2)
    nine_slice(out, "menu", 22, rgba(p["SURFACE_CONTAINER"], 200), rgba(p["ON_SURFACE"], 30), 1)
    nine_slice(out, "bar", 4, rgba(p["SURFACE_CONTAINER_HIGH"], 255))
    nine_slice(out, "bar_hl", 4, rgba(p["PRIMARY"], 255))

    (out / "theme.txt").write_text(f"""\
# Celestia theme for the USB stick GRUB menu, generated by scripts/make_theme.py
desktop-image: "background.png"
desktop-image-scale-method: "crop"
title-text: ""
terminal-font: "Celestia Regular 20"
message-font: "Celestia Regular 20"
message-color: "{p["ON_SURFACE_VARIANT"]}"

+ label {{
    top = 50%-100
    left = 0
    width = 100%
    align = "center"
    text = "Celestia"
    font = "Celestia Regular 32"
    color = "{p["ON_SURFACE"]}"
}}

+ boot_menu {{
    left = 50%-320
    top = 50%-20
    width = 640
    height = 200
    menu_pixmap_style = "menu_*.png"
    item_font = "Celestia Regular 20"
    item_color = "{p["ON_SURFACE_VARIANT"]}"
    selected_item_font = "Celestia Regular 20"
    selected_item_color = "{p["ON_SURFACE"]}"
    selected_item_pixmap_style = "select_*.png"
    item_height = 48
    item_padding = 16
    item_spacing = 8
    icon_width = 0
    icon_height = 0
    scrollbar = false
}}

+ progress_bar {{
    id = "__timeout__"
    left = 50%-320
    top = 50%+210
    width = 640
    height = 8
    bar_style = "bar_*.png"
    highlight_style = "bar_hl_*.png"
    show_text = false
}}

+ label {{
    id = "__timeout__"
    left = 0
    top = 50%+235
    width = 100%
    align = "center"
    font = "Celestia Regular 20"
    color = "{p["OUTLINE"]}"
    text = "Запуск через %d с"
}}
""")


# ------------------------------------------------------------------ Calamares, wallpaper


def make_calamares(out: Path, wall: Image.Image, logo: Image.Image, p) -> None:
    out.mkdir(parents=True, exist_ok=True)
    logo.resize((256, 256), Image.LANCZOS).save(out / "logo.png")
    logo.resize((64, 64), Image.LANCZOS).save(out / "icon.png")
    welcome = backdrop(wall, 1200, 520, blur=0, dim=70, colour=p["BACKGROUND"])
    welcome.putalpha(rounded(1200, 520, 36, (255, 255, 255, 255)).getchannel("A"))
    welcome.save(out / "welcome.png")
    backdrop(wall, 1600, 900, blur=24, dim=185, colour=p["BACKGROUND"]).convert("RGB").save(out / "slide-background.png")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--palette", type=Path, required=True)
    ap.add_argument("--wallpaper", type=Path, required=True)
    ap.add_argument("--logo-png", type=Path, required=True, help="caelestia logo rendered to a large PNG")
    ap.add_argument("--font", type=Path, required=True, help="monospace TTF for the rEFInd font")
    ap.add_argument("--refind", type=Path, required=True)
    ap.add_argument("--grub", type=Path, required=True)
    ap.add_argument("--calamares", type=Path, required=True)
    ap.add_argument("--wallpapers", type=Path, required=True)
    ap.add_argument("--width", type=int, default=2560, help="boot menu background width")
    ap.add_argument("--height", type=int, default=1440, help="boot menu background height")
    args = ap.parse_args()

    p = load_palette(args.palette)
    wall = Image.open(args.wallpaper)
    wall.load()
    logo = Image.open(args.logo_png).convert("RGBA")

    for d in (args.refind, args.grub, args.calamares, args.wallpapers):
        if d.exists():
            shutil.rmtree(d)

    make_refind(args.refind, wall, logo, args.font, p, args.width, args.height)
    make_grub(args.grub, wall, logo, p)
    make_calamares(args.calamares, wall, logo, p)
    args.wallpapers.mkdir(parents=True)
    shutil.copy(args.wallpaper, args.wallpapers / "celestia.webp")


if __name__ == "__main__":
    main()
