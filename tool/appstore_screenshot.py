#!/usr/bin/env python3
"""Compose an App Store marketing screenshot from a raw device capture.

Apple constrains the *canvas* dimensions (pixel-exact per display slot) but not
the layout inside it, so a single device shot with a headline over a coloured
background is a legitimate screenshot. This builds that, following the layout
system popularised by Infuse/VLC-style composites:

  * one dominant device, bleeding off the bottom edge
  * one bold headline line (or two) and a short subhead
  * generous margins and a consistent vertical rhythm

The bleed matters: without it the screenshot reads as a floating rectangle
rather than a device, and it fills the frame at the 1/3 width App Store search
results render at.

Usage:
    tool/appstore_screenshot.py --capture shot.png --out out.png \\
        --headline "Every title." "Perfect artwork." \\
        --subhead "TMDB posters, backdrops and stills - cached for offline"

    tool/appstore_screenshot.py --validate out.png
"""

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# Apple's accepted screenshot dimensions. Anything else is rejected on upload.
ACCEPTED = {
    "iphone-6.9-portrait": [(1320, 2868), (1290, 2796), (1260, 2736)],
    "iphone-6.9-landscape": [(2868, 1320), (2796, 1290), (2736, 1260)],
    "iphone-6.5-portrait": [(1284, 2778), (1242, 2688)],
    # Current App Store Connect classes (iOS 18 naming). ASC rejects a 6.9"
    # upload for these slots -- "File dimensions are invalid".
    "iphone-6.3-portrait": [(1206, 2622)],
    "iphone-6.3-landscape": [(2622, 1206)],
    "iphone-6.1-portrait": [(1179, 2556)],
    "iphone-6.1-landscape": [(2556, 1179)],
    "ipad-13-portrait": [(2048, 2732), (2064, 2752)],
    "ipad-13-landscape": [(2752, 2064), (2732, 2048)],
}

# Two systems, chosen from what the top performers actually ship.
#
# "light" follows VN (4.8 stars, 319k ratings): a near-white canvas, NO device
# mockup at all, one short headline, and the app's own dark UI sitting on it as a
# rounded card. The contrast is the point -- dark UI on white reads as punchy,
# whereas a dark screenshot on a dark canvas has almost no separation and looks
# like a washed-out rectangle. They also skip device frames entirely: rounded
# corners plus a soft shadow are enough, and a mockup only adds clutter.
#
# "dark" is the previous Infuse-style treatment, kept because a dark canvas suits
# full-bleed hero art (a real film frame) better than a white one does.
STYLES = {
    "light": dict(bg_top=(0xFF, 0xFF, 0xFF), bg_bottom=(0xF1, 0xF1, 0xF5),
                  accent=(0x6B, 0x54, 0xB8), head=(0x11, 0x11, 0x14),
                  sub=(0x6B, 0x6B, 0x7A), glow=0, bezel=0.0,
                  body_top=None, body_bottom=None, hairline=0,
                  shadow_alpha=0.30, radius=0.030),
    # "bare" = the app's own theme (#0e0e11 + violet glow) with the capture
    # placed as a plain rectangle: no bezel, no rounded "iPad" corners, no
    # hairline edge. VN uses no device mockup at all -- just the screenshot. The
    # radial glow is what defines the edges instead of an outline, so the UI
    # reads as floating rather than framed.
    "bare": dict(bg_top=(0x14, 0x12, 0x1E), bg_bottom=(0x0A, 0x0A, 0x0D),
                 accent=(0x6B, 0x54, 0xB8), head=(255, 255, 255),
                 sub=(0x9C, 0x9C, 0xB2), glow=150, bezel=0.0,
                 body_top=None, body_bottom=None, hairline=0,
                 shadow_alpha=0.55, radius=0.0),
    "dark": dict(bg_top=(0x16, 0x14, 0x20), bg_bottom=(0x0A, 0x0A, 0x0D),
                 accent=(0x6B, 0x54, 0xB8), head=(255, 255, 255),
                 sub=(0x9C, 0x9C, 0xB2), glow=120, bezel=0.021,
                 body_top=(0x3A, 0x3A, 0x46), body_bottom=(0x20, 0x20, 0x28),
                 hairline=60, shadow_alpha=0.8, radius=0.036),
}
DEFAULT_STYLE = "light"

FONT_DIR = Path("/usr/share/fonts/truetype")
FONT_BOLD = FONT_DIR / "lato/Lato-Bold.ttf"
FONT_REG = FONT_DIR / "lato/Lato-Regular.ttf"
FONT_BLACK = FONT_DIR / "lato/Lato-Black.ttf"


def font(path: Path, size: int) -> ImageFont.FreeTypeFont:
    if not path.exists():  # keep it working on a bare container
        for alt in (FONT_DIR / "liberation/LiberationSans-Bold.ttf",
                    FONT_DIR / "dejavu/DejaVuSans-Bold.ttf"):
            if alt.exists():
                path = alt
                break
    return ImageFont.truetype(str(path), size)


def validate(path: Path) -> int:
    """Exit non-zero unless the file matches an accepted Apple dimension."""
    im = Image.open(path)
    size = im.size
    if im.mode in ("RGBA", "LA", "P"):
        print(f"FAIL  {path.name}: has an alpha channel ({im.mode}) - Apple rejects "
              f"transparency. Re-save as RGB.")
        return 1
    for slot, sizes in ACCEPTED.items():
        if size in sizes:
            print(f"PASS  {path.name}  {size[0]}x{size[1]}  -> {slot}")
            return 0
    print(f"FAIL  {path.name}: {size[0]}x{size[1]} matches no accepted Apple size.")
    for slot, sizes in ACCEPTED.items():
        print(f"        {slot}: {', '.join(f'{w}x{h}' for w, h in sizes)}")
    return 1


def background(w: int, h: int, st: dict) -> Image.Image:
    """Vertical gradient plus an optional soft accent glow behind the device."""
    bg = Image.new("RGB", (w, h), st["bg_bottom"])
    px = bg.load()
    for y in range(h):
        t = (y / max(1, h - 1)) ** 0.85
        row = tuple(int(st["bg_top"][i] + (st["bg_bottom"][i] - st["bg_top"][i]) * t)
                    for i in range(3))
        for x in range(w):
            px[x, y] = row

    if not st["glow"]:
        return bg
    glow = Image.new("L", (w, h), 0)
    gd = ImageDraw.Draw(glow)
    cx, cy, r = w // 2, int(h * 0.60), int(w * 0.72)
    gd.ellipse((cx - r, cy - r, cx + r, cy + r), fill=st["glow"])
    glow = glow.filter(ImageFilter.GaussianBlur(int(w * 0.18)))
    tint = Image.new("RGB", (w, h), st["accent"])
    return Image.composite(Image.blend(bg, tint, 0.55), bg, glow)


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    if radius <= 0:
        d.rectangle((0, 0, size[0] - 1, size[1] - 1), fill=255)
    else:
        d.rounded_rectangle((0, 0, size[0] - 1, size[1] - 1),
                            radius=radius, fill=255)
    return m


def build(capture: Path, out: Path, headline: list[str], subhead: str,
          canvas: tuple[int, int], icon: Path | None, bleed: float,
          device_top: float = 0.345, margin_pct: float = 0.045,
          style: str = DEFAULT_STYLE, trim_top: float = 0.0,
          crop_bottom: float = 0.0) -> None:
    W, H = canvas
    st = STYLES[style]
    bg = background(W, H, st)

    # --- Type block -------------------------------------------------------
    d = ImageDraw.Draw(bg)
    head_font = font(FONT_BLACK if FONT_BLACK.exists() else FONT_BOLD, int(W * 0.072))
    sub_font = font(FONT_REG, int(W * 0.030))

    y = int(H * 0.075)
    if icon and icon.exists():
        size = int(W * 0.085)
        ic = Image.open(icon).convert("RGBA").resize((size, size), Image.LANCZOS)
        mask = rounded_mask((size, size), int(size * 0.22))
        ic.putalpha(Image.composite(ic.getchannel("A"), Image.new("L", (size, size), 0), mask))
        bg.paste(ic, ((W - size) // 2, y), ic)
        y += int(size * 1.45)

    for line in headline:
        bbox = d.textbbox((0, 0), line, font=head_font)
        d.text(((W - (bbox[2] - bbox[0])) // 2 - bbox[0], y), line,
               font=head_font, fill=st["head"])
        y += int((bbox[3] - bbox[1]) * 1.20) + int(W * 0.012)

    if subhead:
        y += int(W * 0.018)
        bbox = d.textbbox((0, 0), subhead, font=sub_font)
        d.text(((W - (bbox[2] - bbox[0])) // 2 - bbox[0], y), subhead,
               font=sub_font, fill=st["sub"])

    # --- Device -----------------------------------------------------------
    # This has to read as *hardware*, not as a large screenshot. Three things
    # do that work, and getting any of them wrong is what makes a composite look
    # amateur:
    #   1. A bezel thick enough to be seen. At 0.75% of width it vanished and
    #      the whole thing read as a borderless screen.
    #   2. The DISPLAY follows the body's corner radius. Pasting a plain
    #      rectangle inside a rounded body leaves square corners poking out,
    #      which is the single strongest "this is just a screenshot" cue.
    #   3. A lit top edge and a darker bottom, so the frame has depth.
    margin = int(W * margin_pct)
    bezel = int(W * st["bezel"])
    dev_w = W - 2 * margin
    cap = Image.open(capture).convert("RGB")
    # Trim the status bar. Real captures carry a clock, carrier and battery,
    # which date the screenshot instantly and add nothing -- App Store art
    # conventionally starts below the status bar. Fraction of capture height so
    # it works across device resolutions.
    if trim_top > 0:
        cut = int(cap.height * trim_top)
        cap = cap.crop((0, cut, cap.width, cap.height))
    # Optionally drop the tail of the capture. Useful when a screen ends in
    # stacked call-to-action buttons: they sit right where the canvas bleed
    # starts, so a half-visible button is the first thing you see. Cropping the
    # source removes them cleanly instead of painting over them.
    if crop_bottom > 0:
        cap = cap.crop((0, 0, cap.width, int(cap.height * (1.0 - crop_bottom))))
    scale = dev_w / cap.width
    cap = cap.resize((dev_w, int(cap.height * scale)), Image.LANCZOS)

    body_radius = int(W * st["radius"])
    screen_radius = max(0, body_radius - bezel)
    dev_h = cap.height + 2 * bezel
    dev_y = int(H * device_top)

    # Screen: rounded to the body's own radius, inset inside the frame.
    screen = Image.new("RGB", (dev_w, cap.height), (0, 0, 0))
    screen.paste(cap, (0, 0))
    screen.putalpha(rounded_mask(screen.size, screen_radius))

    # Body: a lit-top gradient on dark; invisible (just the card) on light.
    body = Image.new("RGB", (dev_w, dev_h))
    if st["body_top"]:
        bpx = body.load()
        for y in range(dev_h):
            t = (y / max(1, dev_h - 1)) ** 0.75
            row = tuple(int(st["body_top"][i] + (st["body_bottom"][i] - st["body_top"][i]) * t)
                        for i in range(3))
            for x in range(dev_w):
                bpx[x, y] = row
    else:
        body.paste(screen.convert("RGB"), (0, 0))
    body = body.convert("RGBA")
    body.paste(screen, (0, bezel), screen)
    body.putalpha(rounded_mask(body.size, body_radius))

    # Hairline edge + the front camera. A single centred dot on the top bezel is
    # what tells the eye "tablet" rather than "monitor".
    edge = Image.new("RGBA", body.size, (0, 0, 0, 0))
    ed = ImageDraw.Draw(edge)
    if st["hairline"]:
        ed.rounded_rectangle((1, 1, body.size[0] - 2, body.size[1] - 2),
                             radius=body_radius,
                             outline=(255, 255, 255, st["hairline"]),
                             width=max(2, int(W * 0.0014)))
    if bezel:
        # Front camera on the top bezel - the detail that says "tablet".
        cam_r = max(3, int(bezel * 0.16))
        ed.ellipse((dev_w // 2 - cam_r, bezel // 2 - cam_r,
                    dev_w // 2 + cam_r, bezel // 2 + cam_r),
                   fill=(12, 12, 16, 255), outline=(255, 255, 255, 34), width=2)
    body.alpha_composite(edge)

    shadow = Image.new("RGBA", body.size, (0, 0, 0, 0))
    shadow.putalpha(body.getchannel("A"))
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(W * 0.030)))
    shadow.putalpha(shadow.getchannel("A").point(
        lambda v: int(v * st["shadow_alpha"])))

    # bleed < 1.0 pushes the bottom edge past the canvas
    visible = int((H - dev_y) / (1.0 - bleed))
    bg.paste(shadow, (margin, dev_y + int(W * 0.014)), shadow)
    visible_body = body.crop((0, 0, dev_w, min(dev_h, visible)))
    bg.paste(visible_body, (margin, dev_y), visible_body)

    out.parent.mkdir(parents=True, exist_ok=True)
    bg.save(out, "PNG", optimize=True)  # RGB, no alpha - Apple rejects transparency
    print(f"wrote {out}  {W}x{H}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--capture")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--headline", nargs="+", default=[])
    ap.add_argument("--subhead", default="")
    ap.add_argument("--canvas", default="ipad-13-portrait")
    ap.add_argument("--icon", type=Path)
    ap.add_argument("--bleed", type=float, default=0.22,
                    help="fraction of the device hidden below the canvas")
    ap.add_argument("--device-top", type=float, default=0.345,
                    help="where the device starts, as a fraction of canvas height")
    ap.add_argument("--margin", type=float, default=0.045,
                    help="device side margin, as a fraction of canvas width")
    ap.add_argument("--style", default=DEFAULT_STYLE, choices=sorted(STYLES),
                    help="bare = app theme, screenshot only (default); light = VN-style")
    ap.add_argument("--trim-top", type=float, default=0.0,
                    help="fraction of the capture's height to crop off the status bar")
    ap.add_argument("--crop-bottom", type=float, default=0.0,
                    help="fraction of the capture's height to crop off the bottom")
    ap.add_argument("--validate", type=Path)
    a = ap.parse_args()

    if a.validate:
        return validate(a.validate)
    if not a.capture or not a.out:
        ap.error("--capture and --out are required")
    if a.canvas not in ACCEPTED:
        ap.error(f"--canvas must be one of {', '.join(ACCEPTED)}")
    build(Path(a.capture), a.out, a.headline, a.subhead, ACCEPTED[a.canvas][0],
          a.icon, a.bleed, a.device_top, a.margin, a.style, a.trim_top,
          a.crop_bottom)
    return validate(a.out)


if __name__ == "__main__":
    sys.exit(main())
