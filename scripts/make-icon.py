#!/usr/bin/env python3
"""
make-icon.py — 生成 Deep Sleep 的应用图标。

在 macOS 的 Asset Catalog 里，图标必须是一组固定尺寸的 PNG。
这里从矢量式的绘制逻辑直接产出全部 10 张，避免依赖外部设计稿。

用法：
    python3 scripts/make-icon.py

设计规范（macOS Big Sur 之后）：
    画布 1024x1024，内容区 824x824 居中，圆角半径 185。
    圆角外的区域必须完全透明。

构图：单体月牙。
    深蓝紫夜空做底，一枚冷蓝→淡紫渐变的月牙偏右居中，
    外缘一道亮边撑出体积感，月牙下方一层很淡的投影。
    背景撒三颗星，仅此而已。

为什么是「只有一个月亮」：
    上一版是「月相表盘」—— 月亮 + 蓝色玻璃钟盘 + 12 根刻度 + 金指针 + 8 颗星。
    钟是白天的符号、月亮是夜晚的符号，两个主体互相打架；
    月亮还被钟盘啃掉一块，糊成一坨脏色；32px 下刻度变毛刺、指针糊成黄斑。
    图标在 Dock 里只有 32~64px 可看，主体只能有一个。

为什么不用光环：
    试过，细光环在 32px 下会糊成一圈灰边，比没有更脏。
    macOS 的体积感靠边缘反光和投影撑，不靠装饰圈。

配色：
    冷色版（默认）—— 夜蓝紫底 + 冷蓝→淡紫月牙 + 白色亮边。
    暖色版 —— 同一构图，底色偏紫、月牙改奶油金。
    换配色改下面 PALETTES 里的取值即可，几何参数不用动。

同时产出：
    docs/images/icon.png（README 顶部那张，512x512）
    与 AppIcon.appiconset/icon_512x512.png 逐字节一致，
    避免 README 上的图和应用里的图标各走各的。

注意：
    - 所有元素最后都要与 824 圆角方形遮罩求交。
    - 月牙的 alpha 必须先挖洞再参与运算：直接模糊一个完整的圆，
      会在月牙缺口处残留一个灰色圆盘，深色背景上非常明显。
"""

import math
import os
from PIL import Image, ImageDraw, ImageFilter

CANVAS = 1024
BOX = (100, 100, 924, 924)
CORNER_RADIUS = 185

# 月牙几何
CENTER = (498, 512)
RADIUS = 292
CUT_RATIO = 0.72      # 挖洞圆心偏移 / 月牙半径
CUT_SCALE = 0.93      # 挖洞圆半径 / 月牙半径
CUT_ANGLE = 214       # 开口朝向（度，0 = 右，顺时针；214 = 左上）

# 配色方案
PALETTES = {
    "cool": {
        "bg": [(0.00, (8, 17, 44)), (0.46, (16, 27, 72)), (1.00, (38, 20, 76))],
        "moon": [(0.00, (238, 246, 255)), (0.40, (154, 192, 255)), (1.00, (206, 146, 255))],
        "glow": (92, 146, 255),
        "star": (214, 230, 255),
    },
    "warm": {
        "bg": [(0.00, (16, 14, 46)), (0.46, (30, 22, 70)), (1.00, (58, 26, 74))],
        "moon": [(0.00, (255, 252, 240)), (0.42, (255, 233, 186)), (1.00, (247, 197, 128))],
        "glow": (255, 206, 130),
        "star": (236, 222, 200),
    },
}

DEFAULT_PALETTE = "cool"

STARS = [(236, 300, 4), (792, 706, 5), (700, 226, 4)]

OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "DeepSleep", "Resources", "Assets.xcassets", "AppIcon.appiconset",
)

README_ICON = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "docs", "images", "icon.png",
)

# Asset Catalog 要求的文件名 → 像素尺寸
SIZES = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}


# ---------- 基础工具 ----------

def rounded_mask():
    """824 圆角方形遮罩。"""
    m = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(m).rounded_rectangle(BOX, radius=CORNER_RADIUS, fill=255)
    return m


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def vertical_gradient(stops):
    """自上而下的多段渐变。stops = [(位置0..1, (r,g,b)), ...]"""
    img = Image.new("RGB", (CANVAS, CANVAS))
    px = img.load()
    assert px is not None  # Pillow 的 load() 类型标注是 Optional
    for y in range(CANVAS):
        t = y / (CANVAS - 1)
        c = stops[-1][1]
        for i in range(len(stops) - 1):
            p0, c0 = stops[i]
            p1, c1 = stops[i + 1]
            if t < p0:
                c = c0
                break
            if p0 <= t <= p1:
                k = 0 if p1 == p0 else (t - p0) / (p1 - p0)
                c = lerp(c0, c1, k)
                break
        for x in range(CANVAS):
            px[x, y] = c
    return img


def crescent_mask():
    """外圆减去一个偏移圆，剩下的弯月。返回 (遮罩, 挖洞圆心, 挖洞半径)。"""
    m = Image.new("L", (CANVAS, CANVAS), 0)
    d = ImageDraw.Draw(m)
    cx, cy = CENTER
    d.ellipse([cx - RADIUS, cy - RADIUS, cx + RADIUS, cy + RADIUS], fill=255)

    a = math.radians(CUT_ANGLE)
    ox = cx + math.cos(a) * RADIUS * CUT_RATIO
    oy = cy + math.sin(a) * RADIUS * CUT_RATIO
    cr = RADIUS * CUT_SCALE
    d.ellipse([ox - cr, oy - cr, ox + cr, oy + cr], fill=0)
    return m, (ox, oy), cr


def radial_light(center, radius, color, strength):
    """中心向外的柔光层。"""
    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for i in range(48, 0, -1):
        r = radius * i / 48
        a = int(255 * strength * (1 - i / 48) ** 2)
        d.ellipse([center[0] - r, center[1] - r, center[0] + r, center[1] + r],
                  fill=color + (a,))
    return layer.filter(ImageFilter.GaussianBlur(radius * 0.08))


def drop_shadow(mask, offset=20, blur=26, alpha=0.5, color=(5, 7, 24)):
    """月牙下方的柔和投影，给出厚度。"""
    blurred = mask.filter(ImageFilter.GaussianBlur(blur))
    off = Image.new("L", (CANVAS, CANVAS), 0)
    off.paste(blurred, (0, offset))
    off = off.point(lambda v: int(v * alpha))
    chans = [Image.new("L", (CANVAS, CANVAS), c) for c in color]
    return Image.merge("RGBA", chans + [off])


def rim_light(mask, width=7, alpha=150):
    """沿月牙外缘的一道亮边 —— 体积感主要靠它。"""
    eroded = mask.filter(ImageFilter.MinFilter(3))
    for _ in range(width):
        eroded = eroded.filter(ImageFilter.MinFilter(3))

    # mask - eroded = 月牙的边界环
    edge = Image.frombytes("L", (CANVAS, CANVAS),
                           bytes((a - b) & 0xFF
                                 for a, b in zip(mask.tobytes(), eroded.tobytes())))
    edge = edge.filter(ImageFilter.GaussianBlur(radius=1.2))
    edge = edge.point(lambda v: min(255, int(v * 2.2)))

    # 只留外缘（外圆那一侧），挖洞那一侧的边不要
    cx, cy = CENTER
    a = math.radians(CUT_ANGLE)
    ox = cx + math.cos(a) * RADIUS * CUT_RATIO
    oy = cy + math.sin(a) * RADIUS * CUT_RATIO
    cr = RADIUS * CUT_SCALE
    outer = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(outer).ellipse([cx - RADIUS, cy - RADIUS,
                                    cx + RADIUS, cy + RADIUS], fill=255)
    inner = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(inner).ellipse([ox - cr, oy - cr, ox + cr, oy + cr], fill=255)
    outer_only = Image.frombytes("L", (CANVAS, CANVAS),
                                 bytes((a - b) & 0xFF
                                       for a, b in zip(outer.tobytes(), inner.tobytes())))
    edge = Image.composite(edge, Image.new("L", (CANVAS, CANVAS), 0), outer_only)

    ch = Image.new("L", (CANVAS, CANVAS), 255)
    return Image.merge("RGBA", [ch, ch, ch, edge.point(lambda v: int(v * alpha / 255))])


def add_stars(target, points, color):
    layer = Image.new("RGBA", target.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for (x, y, r) in points:
        d.ellipse([x - r * 2.4, y - r * 2.4, x + r * 2.4, y + r * 2.4],
                  fill=color + (30,))
        layer = layer.filter(ImageFilter.GaussianBlur(r * 1.5))
        d = ImageDraw.Draw(layer)
        d.ellipse([x - r, y - r, x + r, y + r], fill=color + (225,))
    return Image.alpha_composite(target, layer)


# ---------- 组装 ----------

def build_master(palette_name=DEFAULT_PALETTE):
    """画一张 1024x1024 的完整图标。"""
    palette = PALETTES[palette_name]
    container = rounded_mask()
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

    # 夜空
    sky = vertical_gradient(palette["bg"]).convert("RGBA")
    sky.putalpha(Image.composite(sky.getchannel("A"),
                                 Image.new("L", (CANVAS, CANVAS), 0), container))
    canvas.alpha_composite(sky)

    # 月牙的遮罩先挖好洞，后面所有运算都用它
    mask, _, _ = crescent_mask()

    # 背后柔光
    canvas.alpha_composite(radial_light(CENTER, 400, palette["glow"], 0.26))

    # 投影
    canvas.alpha_composite(drop_shadow(mask))

    # 月牙本体
    moon = vertical_gradient(palette["moon"]).convert("RGBA")
    moon.putalpha(mask)
    canvas.alpha_composite(moon)

    # 外缘亮边
    canvas.alpha_composite(rim_light(mask))

    # 星星
    canvas = add_stars(canvas, STARS, palette["star"])

    # 收在圆角方形内
    canvas.putalpha(Image.composite(canvas.getchannel("A"),
                                    Image.new("L", (CANVAS, CANVAS), 0), container))
    return canvas


def main() -> None:
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    master = build_master()

    for filename, size in SIZES.items():
        target = os.path.join(OUTPUT_DIR, filename)
        master.resize((size, size), Image.LANCZOS).save(target)
        print(f"{filename:24s} {size}x{size}")

    # README 顶部那张：与 icon_512x512.png 逐字节一致
    os.makedirs(os.path.dirname(README_ICON), exist_ok=True)
    master.resize((512, 512), Image.LANCZOS).save(README_ICON)
    print(f"{'docs/images/icon.png':24s} 512x512")

    print(f"\n已写入 {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
