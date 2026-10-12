#!/usr/bin/env python3
"""
生成 AirWear 的 App 图标。

为什么用代码画而不是丢一张 PNG 进来：
  图标是"设计决策"的集合（圆角半径、渐变、进度环占比、图形比例）。
  写成代码之后，改配色或改造型都只是改几个常数，而且能一键重新生成所有尺寸。

用法：
    python3 scripts/make-icon.py                 # 默认声波造型
    python3 scripts/make-icon.py --glyph case    # 换成充电盒造型

产出：
    Resources/AppIcon.icns          打包进 App（Info.plist 的 CFBundleIconFile 指向它）
    docs/images/appicon.png         512px，给 README 用
    build/icon-sizes-check.png      16/32/64 放大对照，用于检查小尺寸可读性

造型选择说明（试过 8 个方案后的结论）：
  中间放什么图形，唯一判据是"缩到 64px 还认不认得出来"。
    · 声波（默认）—— 5 根圆头竖条。64px 仍清晰；而且语义最准：这个应用真正测量的
      信号就是"有没有在出声"（L2）。
    · 充电盒 —— 更像 AirPods，但盒盖缝要么细到缩小后消失，要么粗成一条"信箱口"。
  写实 AirPod 剪影（细长柄那只）在图标尺寸下会读成钥匙/勺子，已放弃。

依赖 Pillow + numpy + 系统自带的 iconutil。
"""

import argparse
import math
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
    import numpy as np
except ImportError:
    sys.exit("需要 Pillow 与 numpy：请用带这些库的解释器运行（pip install pillow numpy）")

# ── 设计参数（想改外观就改这里）─────────────────────────────────

CANVAS = 1024            # 设计画布尺寸（macOS 图标规范 1024）
SUPERSAMPLE = 4          # 超采样倍数，用于抗锯齿

PLATE = 824              # 圆角正方形的边长。macOS 图标网格四周留白约 100px
SQUIRCLE_N = 5.0         # 超椭圆指数；5 接近 Apple 的 squircle 观感（2 就是普通圆角矩形）

COLOR_TOP = (88, 168, 255)      # 渐变：顶部（浅）
COLOR_BOTTOM = (41, 94, 214)    # 渐变：底部（深）

RING_RADIUS = 300        # 进度环半径
RING_WIDTH = 62          # 进度环粗细
RING_SWEEP = 0.75        # 进度环填充比例（0.75 = 转满四分之三）
RING_TRACK_ALPHA = 58    # 未填充部分的透明度（0-255）

WAVE_BARS = [0.36, 0.64, 0.92, 0.64, 0.36]   # 声波各竖条的相对高度
WAVE_BAR_W = 52          # 竖条宽度
WAVE_BAR_GAP = 36        # 竖条间距

CASE_W, CASE_H = 286, 344     # 充电盒尺寸
CASE_SEAM_W = 16              # 盒盖缝粗细（太细会在缩小后消失）
CASE_LED_R = 17               # 指示灯半径

SHADOW_ALPHA = 60        # 中央图形投影强度

# ────────────────────────────────────────────────────────────────


def squircle_points(cx, cy, half, n, steps=1440):
    """超椭圆 |x/a|^n + |y/b|^n = 1 的采样点。n=5 接近 Apple 的 squircle。"""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = half * math.copysign(abs(ct) ** (2.0 / n), ct)
        y = half * math.copysign(abs(st) ** (2.0 / n), st)
        pts.append((cx + x, cy + y))
    return pts


def vertical_gradient(size, top, bottom):
    t = np.linspace(0.0, 1.0, size).reshape(-1, 1, 1)
    col = (1 - t) * np.array(top, dtype=float) + t * np.array(bottom, dtype=float)
    return Image.fromarray(np.repeat(col, size, axis=1).astype("uint8"), "RGB")


def radial_highlight(size, cx_ratio, cy_ratio, radius_ratio, alpha):
    """顶部一团柔和的白色光斑，做玻璃感。"""
    yy, xx = np.mgrid[0:size, 0:size]
    d = np.sqrt((xx - cx_ratio * size) ** 2 + (yy - cy_ratio * size) ** 2)
    a = np.clip(1.0 - d / (radius_ratio * size), 0.0, 1.0) ** 2 * alpha
    layer = np.zeros((size, size, 4), dtype="uint8")
    layer[..., 0:3] = 255
    layer[..., 3] = a.astype("uint8")
    return Image.fromarray(layer, "RGBA")


def glyph_wave(size):
    """声波：一列圆头竖条。"""
    layer = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    d = ImageDraw.Draw(layer)
    k = size / CANVAS
    bw, gap = WAVE_BAR_W * k, WAVE_BAR_GAP * k
    total = len(WAVE_BARS) * bw + (len(WAVE_BARS) - 1) * gap
    x = size / 2 - total / 2
    for f in WAVE_BARS:
        h = 350 * k * f
        d.rounded_rectangle([x, size / 2 - h / 2, x + bw, size / 2 + h / 2],
                            radius=bw / 2, fill=(255, 255, 255, 255))
        x += bw + gap
    return layer


def glyph_case(size):
    """充电盒：圆角矩形 + 盒盖缝 + 指示灯。缝要比直觉更粗，否则缩小后消失。"""
    layer = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    d = ImageDraw.Draw(layer)
    k = size / CANVAS
    w, h = CASE_W * k, CASE_H * k
    x0, y0 = size / 2 - w / 2, size / 2 - h / 2
    d.rounded_rectangle([x0, y0, x0 + w, y0 + h], radius=w * 0.30, fill=(255, 255, 255, 255))
    seam = y0 + h * 0.27
    d.line([x0 + w * 0.04, seam, x0 + w * 0.96, seam],
           fill=COLOR_TOP + (255,), width=int(CASE_SEAM_W * k))
    r = CASE_LED_R * k
    ly = seam + (y0 + h - seam) * 0.32
    d.ellipse([size / 2 - r, ly - r, size / 2 + r, ly + r], fill=COLOR_TOP + (255,))
    return layer


GLYPHS = {"wave": glyph_wave, "case": glyph_case}


def render_master(glyph_name):
    S = CANVAS * SUPERSAMPLE
    k = S / CANVAS

    # 1) 圆角底：渐变 + 顶部高光，用 squircle 当 alpha 蒙版
    plate = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    plate.paste(vertical_gradient(S, COLOR_TOP, COLOR_BOTTOM).convert("RGBA"), (0, 0))
    plate = Image.alpha_composite(plate, radial_highlight(S, 0.5, 0.10, 0.78, 70))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(
        squircle_points(S / 2, S / 2, PLATE / 2 * k, SQUIRCLE_N), fill=255
    )
    plate.putalpha(mask)

    # 2) 进度环：底环 + 填充弧，两端补圆头
    ring = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(ring)
    box = [S / 2 - RING_RADIUS * k] * 2 + [S / 2 + RING_RADIUS * k] * 2
    width = int(RING_WIDTH * k)
    d.arc(box, 0, 360, fill=(255, 255, 255, RING_TRACK_ALPHA), width=width)
    a0, a1 = -90, -90 + 360 * RING_SWEEP
    d.arc(box, a0, a1, fill=(255, 255, 255, 240), width=width)
    for ang in (a0, a1):
        cx = S / 2 + RING_RADIUS * k * math.cos(math.radians(ang))
        cy = S / 2 + RING_RADIUS * k * math.sin(math.radians(ang))
        d.ellipse([cx - width / 2, cy - width / 2, cx + width / 2, cy + width / 2],
                  fill=(255, 255, 255, 240))
    plate = Image.alpha_composite(plate, ring)

    # 3) 中央图形：先投影再叠实体
    glyph = GLYPHS[glyph_name](S)
    shadow = Image.new("RGBA", glyph.size, (0, 0, 0, 0))
    shadow.putalpha(glyph.getchannel("A").point(lambda v: v * SHADOW_ALPHA // 255))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=16 * k))
    plate.alpha_composite(shadow, (0, int(10 * k)))
    plate.alpha_composite(glyph, (0, 0))
    return plate


def main():
    ap = argparse.ArgumentParser(description="生成 AirWear 的 App 图标")
    ap.add_argument("--glyph", choices=sorted(GLYPHS), default="wave",
                    help="中央图形：wave=声波（默认） / case=充电盒")
    args = ap.parse_args()

    root = Path(__file__).resolve().parent.parent
    master = render_master(args.glyph)

    iconset = root / "build" / "AppIcon.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    for f in iconset.glob("*.png"):
        f.unlink()

    # iconutil 需要成对的 基础尺寸 / @2x 命名
    for base, retina in ((16, 32), (32, 64), (128, 256), (256, 512), (512, 1024)):
        master.resize((base, base), Image.LANCZOS).save(iconset / f"icon_{base}x{base}.png")
        master.resize((retina, retina), Image.LANCZOS).save(iconset / f"icon_{base}x{base}@2x.png")

    icns = root / "Resources" / "AppIcon.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True)

    preview = root / "docs" / "images" / "appicon.png"
    preview.parent.mkdir(parents=True, exist_ok=True)
    master.resize((512, 512), Image.LANCZOS).save(preview)

    # 小尺寸可读性检查图（放 build/，不入库）
    strip = Image.new("RGBA", (16 * 8 * 3 + 80, 16 * 8 + 40), (245, 245, 247, 255))
    x = 20
    for s in (16, 32, 64):
        strip.alpha_composite(
            master.resize((s, s), Image.LANCZOS).resize((s * 8, s * 8), Image.NEAREST), (x, 20)
        )
        x += s * 8 + 20
    strip.convert("RGB").save(root / "build" / "icon-sizes-check.png")

    print(f"✅ {icns.relative_to(root)}  ({icns.stat().st_size // 1024} KB，造型={args.glyph})")
    print(f"✅ {preview.relative_to(root)}")
    print("✅ build/icon-sizes-check.png（16/32/64 放大对照）")


if __name__ == "__main__":
    main()
