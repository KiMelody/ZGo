#!/usr/bin/env python3
"""Generate App Store / Google Play marketing assets for ZLinker.

Outputs (under docs/store/):
  appstore/icon/app-icon-1024.png            1024x1024, no alpha
  googleplay/icon/play-icon-512.png          512x512
  googleplay/feature-graphic/*.png           1024x500   (en + zh)
  googleplay/screenshots/phone/*.png         1080x2400  (en + zh)
  googleplay/screenshots/tablet/*.png        1920x1200  (en + zh)

The App Store screenshot sets are NOT generated here anymore: since the
2.3.3 rejection they must show the app in use, so they are assembled from
the native iOS captures by tool/make_appstore_screenshots.py (see
docs/store/SCREENSHOTS.md). The framed App Store composites this script
used to emit are archived under appstore/screenshots/archive-framed/.

Source art: assets/icon/icon.png and the real app captures in
docs/screenshots/. Brand tokens mirror lib/ui/theme.dart (dark #161616,
slate orbit ring, sky #38BDF8 accent, white Z_ glyph).

Run:  python3 tool/gen_store_assets.py
Deps: Pillow  (pip install Pillow)
"""
from __future__ import annotations

import math
import os
import platform
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "store")
SHOTS = os.path.join(ROOT, "docs", "screenshots")
ICON_SRC = os.path.join(ROOT, "assets", "icon", "icon.png")
APP = "ZLinker"

# Fonts: Linux CI uses Inter + WenQuanYi; Windows uses Segoe UI + Microsoft YaHei.
if platform.system() == "Windows":
    FONT_DIR = "C:/Windows/Fonts"
    CJK_FONT = "C:/Windows/Fonts/msyh.ttc"
    _FONT_FILES = {
        "bold": "segoeuib.ttf",
        "semibold": "seguisb.ttf",
        "medium": "segoeui.ttf",
        "regular": "segoeui.ttf",
    }
else:
    FONT_DIR = "/usr/share/fonts/truetype/macos"
    CJK_FONT = "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc"
    _FONT_FILES = {
        "bold": "Inter-Bold.ttf",
        "semibold": "Inter-SemiBold.ttf",
        "medium": "Inter-Medium.ttf",
        "regular": "Inter-Regular.ttf",
    }


def font(weight: str, size: int, lang: str = "en") -> ImageFont.FreeTypeFont:
    if lang == "zh":
        return ImageFont.truetype(CJK_FONT, size)
    return ImageFont.truetype(os.path.join(FONT_DIR, _FONT_FILES[weight]), size)

# ── Brand tokens ────────────────────────────────────────────────────────
BG_TOP = (9, 12, 18)           # deep navy-black
BG_BOTTOM = (18, 21, 28)       # dark, a touch of blue over #161616
CARD = (32, 35, 43)            # elevated card surface
CARD_BORDER = (60, 68, 84)     # slate orbit ring #3A4150-ish
SKY = (56, 189, 248)           # sky-400 #38BDF8
SKY_DEEP = (14, 165, 233)      # sky-500 #0EA5E9
INDIGO = (99, 102, 241)        # indigo-500 (secondary glow)
WHITE = (245, 246, 248)
MUTED = (168, 174, 186)        # cool neutral
DIM = (120, 126, 138)


def is_zh(lang):
    return lang == "zh"


# ── gradients & backgrounds ─────────────────────────────────────────────
def _vgrad(w, h, top, bottom):
    col = Image.new("RGB", (1, h))
    px = col.load()
    for y in range(h):
        t = y / max(1, h - 1)
        px[0, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return col.resize((w, h))


def _radial_glow(w, h, cx, cy, radius, color, strength):
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    d.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=strength)
    m = m.filter(ImageFilter.GaussianBlur(radius * 0.55))
    layer = Image.new("RGB", (w, h), color)
    return layer, m


def orbit_decor(w, h, cx, cy, base_r, alpha=26):
    """Faint concentric rings + one sky arc, echoing the app icon."""
    ov = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    lw = max(2, int(base_r * 0.012))
    for i, mult in enumerate((1.0, 0.72, 0.46)):
        r = int(base_r * mult)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(*CARD_BORDER, alpha), width=lw)
    r = int(base_r * 1.0)
    d.arc([cx - r, cy - r, cx + r, cy + r], start=-120, end=-20,
          fill=(*SKY, alpha + 40), width=lw + 2)
    return ov.filter(ImageFilter.GaussianBlur(1.2))


def background(w, h, glow="tl"):
    base = _vgrad(w, h, BG_TOP, BG_BOTTOM).convert("RGB")
    # primary sky glow
    if glow == "tl":
        sx, sy = int(w * 0.22), int(h * 0.08)
    else:
        sx, sy = int(w * 0.5), int(h * 0.1)
    layer, mask = _radial_glow(w, h, sx, sy, int(w * 0.78), SKY_DEEP, 60)
    base = Image.composite(layer, base, mask)
    # secondary indigo glow bottom-right
    layer2, mask2 = _radial_glow(w, h, int(w * 0.92), int(h * 0.92),
                                 int(w * 0.7), INDIGO, 42)
    base = Image.composite(layer2, base, mask2)
    canvas = base.convert("RGBA")
    canvas.alpha_composite(orbit_decor(w, h, int(w * 0.9), int(h * 0.14), int(w * 0.46)))
    return canvas


# ── shape helpers ───────────────────────────────────────────────────────
def rounded_mask(size, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return m


def drop_shadow(canvas, box, radius, blur, alpha=170, offset=(0, 30)):
    w, h = canvas.size
    sh = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    x0, y0, x1, y1 = box
    ImageDraw.Draw(sh).rounded_rectangle(
        [x0 + offset[0], y0 + offset[1], x1 + offset[0], y1 + offset[1]],
        radius=radius, fill=(0, 0, 0, alpha))
    canvas.alpha_composite(sh.filter(ImageFilter.GaussianBlur(blur)))


def rim_glow(canvas, box, radius, color=SKY, blur=None, alpha=120, grow=None):
    """Soft colored halo around a rounded box, to lift dark device frames."""
    w, h = canvas.size
    grow = grow if grow is not None else int((box[2] - box[0]) * 0.03)
    blur = blur if blur is not None else int((box[2] - box[0]) * 0.05)
    gl = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(gl).rounded_rectangle(
        [box[0] - grow, box[1] - grow, box[2] + grow, box[3] + grow],
        radius=radius + grow, fill=(*color, alpha))
    canvas.alpha_composite(gl.filter(ImageFilter.GaussianBlur(blur)))


def paste_rounded(canvas, img, xy, radius):
    canvas.paste(img, xy, rounded_mask(img.size, radius))


def load_icon(size):
    ic = Image.open(ICON_SRC).convert("RGBA")
    bg = Image.new("RGBA", ic.size, (*BG_BOTTOM, 255))
    ic = Image.alpha_composite(bg, ic)
    return ic.resize((size, size), Image.LANCZOS)


# ── text helpers ────────────────────────────────────────────────────────
def wrap(draw, text, fnt, max_w, lang):
    if is_zh(lang):
        lines, cur = [], ""
        for ch in text:
            if ch == "\n":
                lines.append(cur); cur = ""; continue
            if draw.textlength(cur + ch, font=fnt) <= max_w:
                cur += ch
            else:
                lines.append(cur); cur = ch
        if cur:
            lines.append(cur)
        return lines
    lines = []
    for para in text.split("\n"):
        cur = ""
        for word in para.split():
            trial = (cur + " " + word).strip()
            if draw.textlength(trial, font=fnt) <= max_w:
                cur = trial
            else:
                lines.append(cur); cur = word
        lines.append(cur)
    return lines


def draw_block(draw, text, fnt, fill, x, y, max_w, lang, leading=1.2,
               align="left", stroke=0, stroke_fill=None):
    lines = wrap(draw, text, fnt, max_w, lang)
    asc, desc = fnt.getmetrics()
    lh = int((asc + desc) * leading)
    for i, ln in enumerate(lines):
        lw = draw.textlength(ln, font=fnt)
        lx = x + (max_w - lw) / 2 if align == "center" else x
        draw.text((lx, y + i * lh), ln, font=fnt, fill=fill,
                  stroke_width=stroke, stroke_fill=stroke_fill)
    return y + len(lines) * lh


def draw_title_rich(draw, title, highlight, weight, size, cx, y, max_w, lang):
    """One-line centered title with `highlight` substring colored sky.
    Autofits the font down until it fits max_w."""
    while size > 16:
        fnt = font(weight, size, lang)
        if draw.textlength(title, font=fnt) <= max_w:
            break
        size -= 2
    fnt = font(weight, size, lang)
    stroke = 2 if is_zh(lang) else 0
    if highlight and highlight in title:
        i = title.index(highlight)
        segs = [(title[:i], WHITE), (highlight, SKY), (title[i + len(highlight):], WHITE)]
    else:
        segs = [(title, WHITE)]
    total = sum(draw.textlength(s, font=fnt) for s, _ in segs)
    x = cx - total / 2
    for s, col in segs:
        draw.text((x, y), s, font=fnt, fill=col,
                  stroke_width=stroke, stroke_fill=col if stroke else None)
        x += draw.textlength(s, font=fnt)
    asc, desc = fnt.getmetrics()
    return y + int((asc + desc) * 1.1)


def gradient_text(canvas, text, fnt, center, top_color, bottom_color):
    w, h = canvas.size
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).text(center, text, font=fnt, fill=255, anchor="mm")
    bbox = mask.getbbox()
    grad = _vgrad(w, h, top_color, bottom_color)
    if bbox:
        # vertical gradient limited to the glyph band for punchier color
        band = _vgrad(w, bbox[3] - bbox[1] + 1, top_color, bottom_color)
        grad = Image.new("RGB", (w, h), bottom_color)
        grad.paste(band, (0, bbox[1]))
    canvas.paste(grad, (0, 0), mask)


# ── device frames ───────────────────────────────────────────────────────
def phone_frame(shot, target_w):
    bezel = max(10, int(target_w * 0.033))
    inner_w = target_w - 2 * bezel
    inner_h = int(inner_w * shot.size[1] / shot.size[0])
    shot = shot.convert("RGB").resize((inner_w, inner_h), Image.LANCZOS)
    fw, fh = target_w, inner_h + 2 * bezel
    r = int(target_w * 0.135)
    frame = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    frame.paste(Image.new("RGBA", (fw, fh), (6, 7, 9, 255)), (0, 0), rounded_mask((fw, fh), r))
    paste_rounded(frame, shot, (bezel, bezel), max(4, r - bezel))
    d = ImageDraw.Draw(frame)
    d.rounded_rectangle([0, 0, fw - 1, fh - 1], radius=r, outline=CARD_BORDER, width=max(2, bezel // 4))
    # notch pill
    nw, nh = int(fw * 0.30), int(bezel * 0.85)
    nx = (fw - nw) // 2
    d.rounded_rectangle([nx, bezel - nh // 2, nx + nw, bezel + nh // 2], radius=nh, fill=(6, 7, 9, 255))
    return frame


def browser_frame(shot, target_w):
    pad = max(2, int(target_w * 0.006))
    bar = int(target_w * 0.05)
    inner_w = target_w - 2 * pad
    inner_h = int(inner_w * shot.size[1] / shot.size[0])
    shot = shot.convert("RGB").resize((inner_w, inner_h), Image.LANCZOS)
    fw, fh = target_w, inner_h + bar + pad
    r = int(target_w * 0.022)
    frame = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    frame.paste(Image.new("RGBA", (fw, fh), (26, 28, 34, 255)), (0, 0), rounded_mask((fw, fh), r))
    d = ImageDraw.Draw(frame)
    cy = bar // 2
    for i, col in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        dx = int(bar * 0.6) + i * int(bar * 0.5)
        rr = max(4, int(bar * 0.12))
        d.ellipse([dx - rr, cy - rr, dx + rr, cy + rr], fill=col)
    frame.paste(shot, (pad, bar))
    d.rounded_rectangle([0, 0, fw - 1, fh - 1], radius=r, outline=CARD_BORDER, width=max(2, pad))
    return frame


def wordmark(canvas, cx, y, scale=1.0):
    """Icon + ZLinker + sky underline accent."""
    isz = int(66 * scale)
    ic = load_icon(isz)
    fnt = font("bold", int(46 * scale))
    d = ImageDraw.Draw(canvas)
    tw = d.textlength(APP, font=fnt)
    total = isz + int(18 * scale) + tw
    x = int(cx - total / 2)
    canvas.alpha_composite(ic.convert("RGBA"), (x, int(y)))
    tx = x + isz + int(18 * scale)
    ty = int(y + isz / 2 - int(46 * scale) * 0.62)
    d.text((tx, ty), APP, font=fnt, fill=WHITE)
    uy = int(y + isz + 6 * scale)
    d.rounded_rectangle([tx, uy, tx + tw, uy + max(2, int(4 * scale))],
                        radius=int(2 * scale), fill=SKY)


# ── content ─────────────────────────────────────────────────────────────
CAPTIONS = {
    "tasks": {
        "en": ("Every task, live", "live", "Running state, reply previews, and stop \u00b7 pause \u00b7 resume \u2014 right from your phone."),
        "zh": ("\u4efb\u52a1\uff0c\u5b9e\u65f6\u638c\u63e1", "\u5b9e\u65f6", "\u8fd0\u884c\u72b6\u6001\u3001\u56de\u590d\u9884\u89c8\uff0c\u505c\u6b62 \u00b7 \u6682\u505c \u00b7 \u6062\u590d\uff0c\u968f\u624b\u5b8c\u6210\u3002"),
    },
    "conversation": {
        "en": ("Native conversations", "Native", "Streaming replies, tool diffs and model switching \u2014 no browser needed."),
        "zh": ("\u539f\u751f\u5bf9\u8bdd\u4f53\u9a8c", "\u539f\u751f", "\u6d41\u5f0f\u56de\u590d\u3001\u5de5\u5177 diff\u3001\u6a21\u578b\u5207\u6362\uff0c\u65e0\u9700\u7f51\u9875\u3002"),
    },
    "dualpane": {
        "en": ("Desktop-class on tablet", "Desktop-class", "Sidebar + chat, side by side above 768dp."),
        "zh": ("\u5e73\u677f\u4e0a\u7684\u684c\u9762\u7ea7\u5e03\u5c40", "\u684c\u9762\u7ea7", "768dp \u4ee5\u4e0a\uff0c\u4fa7\u680f + \u5bf9\u8bdd\u53cc\u680f\u5e76\u6392\u3002"),
    },
}

HERO = {
    "en": ("Your ZCode coding agent,\nnow in your pocket.",
           ["Live tasks", "Automations", "Off-peak", "Notifications"]),
    "zh": ("\u628a ZCode \u7f16\u7a0b\u667a\u80fd\u4f53\n\u88c5\u8fdb\u53e3\u888b\u3002",
           ["\u5b9e\u65f6\u4efb\u52a1", "\u5b9a\u65f6\u81ea\u52a8\u5316", "\u95f2\u65f6\u4efb\u52a1", "\u672c\u5730\u901a\u77e5"]),
}

FEATURES = {
    "en": ("Built for real work", "real work", [
        ("Scheduled automations", "cron \u00b7 intervals \u00b7 one-shot"),
        ("Off-peak tasks", "free compute, live queue position"),
        ("Push notifications", "tap to open the conversation"),
        ("Privacy first", "device links stay on your phone"),
    ]),
    "zh": ("\u4e3a\u771f\u5b9e\u5de5\u4f5c\u800c\u751f", "\u771f\u5b9e\u5de5\u4f5c", [
        ("\u5b9a\u65f6\u81ea\u52a8\u5316", "cron \u00b7 \u56fa\u5b9a\u95f4\u9694 \u00b7 \u4e00\u6b21\u6027"),
        ("\u95f2\u65f6\u4efb\u52a1", "\u514d\u8d39\u7b97\u529b\uff0c\u6392\u961f\u5b9e\u65f6\u53ef\u89c1"),
        ("\u63a8\u9001\u901a\u77e5", "\u70b9\u6309\u76f4\u8fbe\u5bf9\u8bdd"),
        ("\u9690\u79c1\u4f18\u5148", "\u8bbe\u5907\u94fe\u63a5\u53ea\u5b58\u672c\u673a"),
    ]),
}


# ── slides ──────────────────────────────────────────────────────────────
def showcase_portrait(w, h, shot_path, key, lang):
    canvas = background(w, h)
    d = ImageDraw.Draw(canvas)
    title, hl, sub = CAPTIONS[key][lang]
    margin = int(w * 0.085)
    y = draw_title_rich(d, title, hl, "bold", int(w * 0.082),
                        w / 2, int(h * 0.058), w - 2 * margin, lang)
    y += int(h * 0.006)
    draw_block(d, sub, font("medium", int(w * 0.036), lang), MUTED,
               margin, y, w - 2 * margin, lang, align="center", leading=1.3)

    shot = Image.open(shot_path)
    frame = phone_frame(shot, int(w * 0.72))
    fx = (w - frame.size[0]) // 2
    fy = int(h * 0.30)
    if fy + frame.size[1] > h * 0.92:
        frame = phone_frame(shot, int((h * 0.92 - fy) * shot.size[0] / shot.size[1] * 0.96))
        fx = (w - frame.size[0]) // 2
    box = [fx, fy, fx + frame.size[0], fy + frame.size[1]]
    r = int(frame.size[0] * 0.135)
    drop_shadow(canvas, box, r, int(w * 0.045))
    rim_glow(canvas, box, r, SKY, alpha=95)
    canvas.alpha_composite(frame, (fx, fy))
    wordmark(canvas, w / 2, h * 0.94, scale=w / 1290 * 0.92)
    return canvas.convert("RGB")


def showcase_landscape(w, h, shot_path, key, lang):
    canvas = background(w, h, glow="top")
    d = ImageDraw.Draw(canvas)
    title, hl, sub = CAPTIONS[key][lang]
    y = draw_title_rich(d, title, hl, "bold", int(w * 0.038),
                        w / 2, int(h * 0.055), int(w * 0.86), lang)
    y += int(h * 0.006)
    draw_block(d, sub, font("medium", int(w * 0.019), lang), MUTED,
               int(w * 0.07), y, int(w * 0.86), lang, align="center")

    shot = Image.open(shot_path)
    avail_top, avail_h = int(h * 0.24), int(h * 0.64)
    frame = browser_frame(shot, int(w * 0.80))
    if frame.size[1] > avail_h:
        frame = browser_frame(shot, int(w * 0.80 * avail_h / frame.size[1]))
    fx = (w - frame.size[0]) // 2
    fy = avail_top + (avail_h - frame.size[1]) // 2
    box = [fx, fy, fx + frame.size[0], fy + frame.size[1]]
    r = int(frame.size[0] * 0.022)
    drop_shadow(canvas, box, r, int(w * 0.02))
    rim_glow(canvas, box, r, SKY, alpha=80)
    canvas.alpha_composite(frame, (fx, fy))
    wordmark(canvas, w / 2, h * 0.95, scale=w / 2752 * 1.4)
    return canvas.convert("RGB")


def hero_slide(w, h, lang):
    canvas = background(w, h, glow="top")
    d = ImageDraw.Draw(canvas)
    isz = int(w * 0.44)
    ic = load_icon(isz)
    ix, iy = (w - isz) // 2, int(h * 0.15)
    box = [ix, iy, ix + isz, iy + isz]
    drop_shadow(canvas, box, int(isz * 0.23), int(w * 0.05), alpha=180)
    rim_glow(canvas, box, int(isz * 0.23), SKY, alpha=110, grow=int(isz * 0.05), blur=int(w * 0.06))
    canvas.alpha_composite(ic.convert("RGBA"), (ix, iy))

    # gradient wordmark
    gradient_text(canvas, APP, font("bold", int(w * 0.125)),
                  (w / 2, iy + isz + int(h * 0.055)), WHITE, SKY)
    d = ImageDraw.Draw(canvas)
    # accent underline under wordmark
    tw = d.textlength(APP, font=font("bold", int(w * 0.125)))
    uy = iy + isz + int(h * 0.055) + int(w * 0.075)
    d.rounded_rectangle([w / 2 - tw * 0.28, uy, w / 2 + tw * 0.28, uy + int(w * 0.008)],
                        radius=int(w * 0.004), fill=SKY)

    tag, chips = HERO[lang]
    draw_block(d, tag, font("semibold", int(w * 0.05), lang), MUTED,
               int(w * 0.08), uy + int(h * 0.03), int(w * 0.84), lang,
               align="center", leading=1.26)

    cf = font("semibold", int(w * 0.032), lang)
    ch_h = int(w * 0.088)
    gap = int(w * 0.03)
    cy = int(h * 0.79)
    for r_i, row in enumerate((chips[:2], chips[2:])):
        widths = [d.textlength(c, font=cf) + int(w * 0.075) for c in row]
        total = sum(widths) + gap * (len(row) - 1)
        x = (w - total) / 2
        yy = cy + r_i * (ch_h + int(h * 0.016))
        for c, cw in zip(row, widths):
            d.rounded_rectangle([x, yy, x + cw, yy + ch_h], radius=ch_h // 2,
                                fill=CARD, outline=CARD_BORDER, width=2)
            dot = int(ch_h * 0.11)
            dcx = x + int(w * 0.03)
            d.ellipse([dcx - dot, yy + ch_h / 2 - dot, dcx + dot, yy + ch_h / 2 + dot], fill=SKY)
            d.text((dcx + int(w * 0.022), yy + ch_h / 2), c, font=cf, fill=WHITE, anchor="lm")
            x += cw + gap
    return canvas.convert("RGB")


def features_slide(w, h, lang):
    canvas = background(w, h)
    d = ImageDraw.Draw(canvas)
    title, hl, items = FEATURES[lang]
    y = draw_title_rich(d, title, hl, "bold", int(w * 0.082),
                        w / 2, int(h * 0.075), int(w * 0.86), lang)
    y += int(h * 0.03)
    cx0 = int(w * 0.08)
    cw = w - 2 * cx0
    ch = int(h * 0.138)
    gap = int(h * 0.028)
    tf = font("semibold", int(w * 0.049), lang)
    sf = font("regular", int(w * 0.033), lang)
    for i, (t, s) in enumerate(items):
        yy = y + i * (ch + gap)
        d.rounded_rectangle([cx0, yy, cx0 + cw, yy + ch], radius=int(w * 0.05),
                            fill=CARD, outline=CARD_BORDER, width=2)
        sq = int(ch * 0.58)
        sx, sy = cx0 + int(w * 0.05), yy + (ch - sq) // 2
        # sky gradient tile
        tile = _vgrad(sq, sq, SKY, SKY_DEEP).convert("RGBA")
        canvas.paste(tile, (sx, sy), rounded_mask((sq, sq), int(sq * 0.3)))
        d.text((sx + sq / 2, sy + sq / 2), str(i + 1),
               font=font("bold", int(sq * 0.5)), fill=(6, 18, 28), anchor="mm")
        tx = sx + sq + int(w * 0.05)
        d.text((tx, yy + ch * 0.32), t, font=tf, fill=WHITE, anchor="lm")
        d.text((tx, yy + ch * 0.67), s, font=sf, fill=MUTED, anchor="lm")
    wordmark(canvas, w / 2, h * 0.94, scale=w / 1290 * 0.92)
    return canvas.convert("RGB")


def feature_graphic(lang):
    w, h = 1024, 500
    canvas = background(w, h, glow="tl")
    d = ImageDraw.Draw(canvas)
    isz = 300
    ic = load_icon(isz)
    ix, iy = 74, (h - isz) // 2
    box = [ix, iy, ix + isz, iy + isz]
    drop_shadow(canvas, box, int(isz * 0.23), 28, alpha=160)
    rim_glow(canvas, box, int(isz * 0.23), SKY, alpha=110, grow=14, blur=34)
    canvas.alpha_composite(ic.convert("RGBA"), (ix, iy))
    d = ImageDraw.Draw(canvas)
    tx = ix + isz + 60
    avail = w - tx - 44

    def fit(text, weight, start, lang):
        sz = start
        while sz > 12 and d.textlength(text, font=font(weight, sz, lang)) > avail:
            sz -= 2
        return sz

    gradient_text(canvas, APP, font("bold", fit(APP, "bold", 118, "en")),
                  (tx + d.textlength(APP, font=font("bold", fit(APP, "bold", 118, "en"))) / 2, 158),
                  WHITE, SKY)
    d = ImageDraw.Draw(canvas)
    sub = {"en": "Remote for ZCode agents", "zh": "ZCode \u667a\u80fd\u4f53\u8fdc\u7a0b\u63a7\u5236"}[lang]
    d.text((tx, 262), sub, font=font("semibold", fit(sub, "semibold", 46, lang), lang), fill=SKY, anchor="lm")
    tags = {"en": "Tasks \u00b7 Automations \u00b7 Off-peak \u00b7 Notifications",
            "zh": "\u4efb\u52a1 \u00b7 \u81ea\u52a8\u5316 \u00b7 \u95f2\u65f6 \u00b7 \u901a\u77e5"}[lang]
    d.text((tx, 326), tags, font=font("medium", fit(tags, "medium", 32, lang), lang), fill=MUTED, anchor="lm")
    return canvas.convert("RGB")


def ensure(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return path


def main():
    # Real app captures (integration_test/screenshots_test.dart, seeded data).
    # raw/ portrait captures are the native iPhone 1320x2868 shots; raw/
    # 04-dualpane is the older Android landscape capture (the iPad slot now
    # uses the native raw-ipad/05-dualpane portrait capture instead). Each
    # locale gets its matching UI capture so the embedded screenshot text
    # aligns with the caption.
    def shot(name, lang):
        return os.path.join(SHOTS, "raw", f"{name}-{lang}.png")

    load_icon(1024).convert("RGB").save(ensure(os.path.join(OUT, "appstore/icon/app-icon-1024.png")))
    load_icon(512).convert("RGB").save(ensure(os.path.join(OUT, "googleplay/icon/play-icon-512.png")))

    for lang in ("en", "zh"):
        feature_graphic(lang).save(ensure(os.path.join(OUT, f"googleplay/feature-graphic/feature-graphic-{lang}.png")))

    W, H = 1080, 2400
    for lang in ("en", "zh"):
        hero_slide(W, H, lang).save(ensure(os.path.join(OUT, f"googleplay/screenshots/phone/00-hero-{lang}.png")))
        showcase_portrait(W, H, shot("02-tasks", lang), "tasks", lang).save(os.path.join(OUT, f"googleplay/screenshots/phone/01-tasks-{lang}.png"))
        showcase_portrait(W, H, shot("03-chat", lang), "conversation", lang).save(os.path.join(OUT, f"googleplay/screenshots/phone/02-conversation-{lang}.png"))
        features_slide(W, H, lang).save(os.path.join(OUT, f"googleplay/screenshots/phone/03-features-{lang}.png"))

    W, H = 1920, 1200
    for lang in ("en", "zh"):
        showcase_landscape(W, H, shot("04-dualpane", lang), "dualpane", lang).save(ensure(os.path.join(OUT, f"googleplay/screenshots/tablet/01-dualpane-{lang}.png")))

    print("Store assets written to", OUT)


if __name__ == "__main__":
    main()
