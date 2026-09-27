#!/usr/bin/env python3
"""
make-icon.py — 生成 Deep Sleep 的应用图标。

在 macOS 的 Asset Catalog 里，图标必须是一组固定尺寸的 PNG。
这里从矢量式的绘制逻辑直接产出全部 10 张，避免依赖外部设计稿。

用法：
    python3 scripts/make-icon.py

设计规范（macOS Big Sur 之后）：
    画布 1024x1024，内容区 824x824 居中，圆角半径 185.4。
    圆角外的区域必须完全透明。

注意：发光层必须用「挖洞之后」的月牙 alpha 去生成。
早期版本直接模糊一个完整的圆，结果月牙缺口处残留了一个灰色圆盘，
在深色背景上非常明显。
"""

import os
from PIL import Image, ImageDraw, ImageFilter

CANVAS = 1024
CONTENT = 824
CORNER_RADIUS = 185
BACKGROUND_TOP = (28, 26, 62)
BACKGROUND_BOTTOM = (74, 52, 122)
MOON_COLOR = (255, 232, 150)
STAR_COLOR = (255, 255, 255, 235)

# 月牙：大圆减去一个向右上偏移的圆
MOON_CENTER = (470, 512)
MOON_RADIUS = 250
CUTOUT_CENTER = (600, 430)
CUTOUT_RADIUS = 232

STARS = [
    (700, 700, 26),
    (790, 610, 15),
    (660, 810, 12),
    (760, 480, 10),
    (330, 300, 11),
    (250, 690, 9),
]

OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "DeepSleep", "Resources", "Assets.xcassets", "AppIcon.appiconset",
)

# Asset Catalog 要求的文件名 → 像素尺寸
SIZES = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}


def rounded_square_mask() -> Image.Image:
    """按 macOS 规范生成圆角方形遮罩。"""
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    draw = ImageDraw.Draw(mask)
    pad = (CANVAS - CONTENT) // 2
    draw.rounded_rectangle(
        [pad, pad, CANVAS - pad, CANVAS - pad],
        radius=CORNER_RADIUS,
        fill=255,
    )
    return mask


def background() -> Image.Image:
    """深靛蓝到紫色的对角渐变。"""
    gradient = Image.new("RGBA", (CANVAS, CANVAS))
    pixels = gradient.load()
    for y in range(CANVAS):
        for x in range(CANVAS):
            t = min(1.0, max(0.0, (x * 0.35 + y * 0.65) / CANVAS))
            pixels[x, y] = (
                int(BACKGROUND_TOP[0] + (BACKGROUND_BOTTOM[0] - BACKGROUND_TOP[0]) * t),
                int(BACKGROUND_TOP[1] + (BACKGROUND_BOTTOM[1] - BACKGROUND_TOP[1]) * t),
                int(BACKGROUND_TOP[2] + (BACKGROUND_BOTTOM[2] - BACKGROUND_TOP[2]) * t),
                255,
            )
    return gradient


def moon_layer() -> Image.Image:
    """透明背景上的月牙，发光层要用它的 alpha。"""
    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cx, cy = MOON_CENTER
    draw.ellipse(
        [cx - MOON_RADIUS, cy - MOON_RADIUS, cx + MOON_RADIUS, cy + MOON_RADIUS],
        fill=MOON_COLOR + (255,),
    )
    ox, oy = CUTOUT_CENTER
    # 用 alpha=0 的椭圆把「洞」抠出来
    draw.ellipse(
        [ox - CUTOUT_RADIUS, oy - CUTOUT_RADIUS, ox + CUTOUT_RADIUS, oy + CUTOUT_RADIUS],
        fill=(0, 0, 0, 0),
    )
    return layer


def build_master() -> Image.Image:
    mask = rounded_square_mask()

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(background(), (0, 0), mask)

    moon = moon_layer()

    # 发光：对「挖洞后」的月牙 alpha 做模糊再着色，
    # 这样光晕严格沿着月牙轮廓，不会在缺口处留下圆盘。
    glow_alpha = moon.getchannel("A").filter(ImageFilter.GaussianBlur(30))
    glow = Image.new("RGBA", (CANVAS, CANVAS), MOON_COLOR + (0,))
    glow.putalpha(glow_alpha.point(lambda value: int(value * 0.62)))
    canvas.alpha_composite(glow)

    canvas.alpha_composite(moon)

    draw = ImageDraw.Draw(canvas, "RGBA")
    for x, y, radius in STARS:
        draw.ellipse(
            [x - radius, y - radius, x + radius, y + radius],
            fill=STAR_COLOR,
        )

    # 圆角外必须干净：把内容区域的 alpha 与遮罩求交
    canvas.putalpha(
        Image.composite(canvas.getchannel("A"), Image.new("L", (CANVAS, CANVAS), 0), mask)
    )
    return canvas


def main() -> None:
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    master = build_master()
    for filename, size in SIZES.items():
        target = os.path.join(OUTPUT_DIR, filename)
        master.resize((size, size), Image.LANCZOS).save(target)
        print(f"{filename:24s} {size}x{size}")
    print(f"\n已写入 {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
