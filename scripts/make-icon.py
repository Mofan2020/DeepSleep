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

构图：月相表盘。
    深蓝夜空做底，蓝色玻璃表盘偏左下，一枚金色月牙从盘后探出压住盘缘。
    时针指向 10 点、分针指向 2 分（10:10 的经典钟面姿态）——
    小尺寸下两针分得开，比用指针编码具体时刻更容易读成「钟」。

同时产出：
    docs/images/icon.png（README 顶部那张，512x512）
    与 AppIcon.appiconset/icon_512x512.png 逐字节一致，
    避免 README 上的图和应用里的图标各走各的。

注意：
    - 所有元素最后都要与 824 圆角方形遮罩求交。月牙画在框外时，
      导出后会被系统裁掉一角。
    - 发光层必须用「挖洞之后」的月牙 alpha 去生成。直接模糊一个完整的圆，
      会在月牙缺口处残留一个灰色圆盘，深色背景上非常明显。
"""

import math
import os
from PIL import Image, ImageDraw, ImageFilter, ImageChops

CANVAS = 1024
BOX = (100, 100, 924, 924)
CORNER_RADIUS = 185

# 配色
BACKGROUND_TOP = (11, 17, 50)
BACKGROUND_BOTTOM = (38, 28, 80)
FACE_TOP = (148, 190, 255, 214)
FACE_BOTTOM = (42, 66, 148, 204)
MOON_TOP = (255, 251, 233)
MOON_BOTTOM = (243, 198, 106)
RIM_COLOR = (238, 246, 255, 180)
TICK_COLOR = (228, 241, 255, 190)
HAND_COLOR = (255, 234, 168, 255)
HUB_COLOR = (255, 247, 220, 255)
STAR_COLOR = (228, 238, 255, 212)

# 表盘
DIAL_CENTER = (470, 548)
DIAL_RADIUS = 236

# 月牙：外圆减去一个偏移圆，剩下的弯月
MOON_CENTER = (700, 356)
MOON_RADIUS = 190
MOON_CUT_RATIO = 0.66      # 挖洞圆心偏移量 / 月牙外圆半径
MOON_CUT_SCALE = 0.90      # 挖洞圆半径 / 月牙外圆半径
MOON_CUT_ANGLE = 133       # 开口朝向

# 指针角度：0 = 12 点，顺时针
HOUR_ANGLE = 300           # 10 点
MINUTE_ANGLE = 60          # 2 分
HOUR_LENGTH = 0.56         # 相对盘面半径
MINUTE_LENGTH = 0.78

STARS = [
    (196, 250, 6), (152, 640, 5), (250, 830, 5),
    (856, 226, 5), (886, 664, 6), (742, 892, 5),
    (352, 172, 4), (182, 716, 4),
]

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


def polar(angle_deg, radius, center=DIAL_CENTER):
    """表盘角（0=12点，顺时针）→ 像素坐标。"""
    a = math.radians(angle_deg)
    return (center[0] + radius * math.sin(a),
            center[1] - radius * math.cos(a))


def circle_mask(cx, cy, r):
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(mask).ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    return mask


def container_mask():
    """824x824 圆角方形遮罩。"""
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [BOX[0], BOX[1], BOX[2], BOX[3]], radius=CORNER_RADIUS, fill=255)
    return mask


def linear_gradient(size, top, bottom, wx=0.30, wy=0.70):
    """斜向线性渐变。wx/wy 是 x、y 方向的权重。"""
    small = Image.new("L", (256, 256))
    pixels = small.load()
    for y in range(256):
        for x in range(256):
            t = min(1.0, max(0.0, (x * wx + y * wy) / 256))
            pixels[x, y] = int(t * 255)
    small = small.resize(size, Image.BICUBIC)
    return Image.composite(
        Image.new("RGBA", size, bottom),
        Image.new("RGBA", size, top), small)


def night_sky():
    """深蓝到靛紫的夜空，带一层柔和光晕和星点。"""
    sky = linear_gradient((CANVAS, CANVAS),
                          BACKGROUND_TOP + (255,),
                          BACKGROUND_BOTTOM + (255,),
                          wx=0.42, wy=0.58)
    sheen = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    ImageDraw.Draw(sheen).ellipse(
        [-340, -470, 600, 270], fill=(120, 150, 235, 46))
    sky.alpha_composite(sheen.filter(ImageFilter.GaussianBlur(175)))

    stars = ImageDraw.Draw(sky, "RGBA")
    for x, y, r in STARS:
        stars.ellipse([x - r, y - r, x + r, y + r], fill=STAR_COLOR)
    return sky


def crescent_mask():
    """月牙形状：外圆减去偏移圆。返回遮罩、挖洞圆心、挖洞半径。"""
    cut_r = MOON_RADIUS * MOON_CUT_SCALE
    cut_d = MOON_RADIUS * MOON_CUT_RATIO
    a = math.radians(MOON_CUT_ANGLE)
    cut_center = (MOON_CENTER[0] + cut_d * math.cos(a),
                  MOON_CENTER[1] + cut_d * math.sin(a))
    crescent = ImageChops.subtract(
        circle_mask(MOON_CENTER[0], MOON_CENTER[1], MOON_RADIUS),
        circle_mask(cut_center[0], cut_center[1], cut_r))
    return crescent, cut_center, cut_r


def paint_crescent(target, crescent, cut_center, cut_r):
    """金色月牙：外溢暖光 + 渐变本体 + 内外两道高光边。"""
    glow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    glow.paste((255, 226, 160, 255), (0, 0), crescent)
    target.alpha_composite(glow.filter(ImageFilter.GaussianBlur(28)))

    body = linear_gradient((CANVAS, CANVAS),
                           MOON_TOP + (255,), MOON_BOTTOM + (255,),
                           wx=0.28, wy=0.72)
    body.putalpha(ImageChops.multiply(body.getchannel("A"), crescent))
    target.alpha_composite(body)

    outer_edge = ImageChops.subtract(
        circle_mask(MOON_CENTER[0], MOON_CENTER[1], MOON_RADIUS),
        circle_mask(MOON_CENTER[0], MOON_CENTER[1], MOON_RADIUS - 11))
    outer_edge = ImageChops.multiply(outer_edge, crescent)
    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    layer.paste((255, 251, 232, 215), (0, 0), outer_edge)
    target.alpha_composite(layer)

    inner_edge = ImageChops.subtract(
        circle_mask(cut_center[0], cut_center[1], cut_r),
        circle_mask(cut_center[0], cut_center[1], cut_r - 9))
    inner_edge = ImageChops.multiply(inner_edge, crescent)
    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    layer.paste((255, 246, 220, 200), (0, 0), inner_edge)
    target.alpha_composite(layer)


def paint_dial(target):
    """蓝色玻璃表盘：盘面 + 外缘亮边 + 刻度。"""
    dial = circle_mask(DIAL_CENTER[0], DIAL_CENTER[1], DIAL_RADIUS)

    face = linear_gradient((CANVAS, CANVAS), FACE_TOP, FACE_BOTTOM)
    gloss = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    ImageDraw.Draw(gloss).ellipse(
        [DIAL_CENTER[0] - DIAL_RADIUS * 0.95, DIAL_CENTER[1] - DIAL_RADIUS,
         DIAL_CENTER[0] + DIAL_RADIUS * 0.2, DIAL_CENTER[1] + DIAL_RADIUS * 0.3],
        fill=(220, 238, 255, 60))
    face.alpha_composite(gloss.filter(ImageFilter.GaussianBlur(90)))
    face.putalpha(ImageChops.multiply(face.getchannel("A"), dial))
    target.alpha_composite(face)

    rim = ImageChops.subtract(
        circle_mask(DIAL_CENTER[0], DIAL_CENTER[1], DIAL_RADIUS),
        circle_mask(DIAL_CENTER[0], DIAL_CENTER[1], DIAL_RADIUS - 14))
    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    layer.paste(RIM_COLOR, (0, 0), rim)
    target.alpha_composite(layer)

    ticks = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(ticks, "RGBA")
    for i in range(12):
        angle = i * 30
        long_mark = i % 3 == 0
        outer = DIAL_RADIUS - 26
        length = 34 if long_mark else 19
        x1, y1 = polar(angle, outer)
        x2, y2 = polar(angle, outer - length)
        draw.line([x1, y1, x2, y2], fill=TICK_COLOR, width=11 if long_mark else 8)
    target.alpha_composite(ticks)


def paint_hands(target):
    """两根指针 + 轴心。"""
    def hand(angle, length_ratio, half_width):
        tip = polar(angle, DIAL_RADIUS * length_ratio)
        side_a = polar(angle + 90, half_width)
        side_b = polar(angle - 90, half_width)
        layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
        ImageDraw.Draw(layer, "RGBA").polygon(
            [tip, side_a, DIAL_CENTER, side_b], fill=HAND_COLOR)
        return layer

    target.alpha_composite(hand(HOUR_ANGLE, HOUR_LENGTH, 24))
    target.alpha_composite(hand(MINUTE_ANGLE, MINUTE_LENGTH, 19))

    hub = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    ImageDraw.Draw(hub, "RGBA").ellipse(
        [DIAL_CENTER[0] - 20, DIAL_CENTER[1] - 20,
         DIAL_CENTER[0] + 20, DIAL_CENTER[1] + 20], fill=HUB_COLOR)
    target.alpha_composite(hub)


def build_master():
    """画一张 1024x1024 的完整图标。"""
    container = container_mask()
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

    sky = night_sky()
    sky.putalpha(ImageChops.multiply(sky.getchannel("A"), container))
    canvas.alpha_composite(sky)

    crescent, cut_center, cut_r = crescent_mask()
    paint_crescent(canvas, crescent, cut_center, cut_r)

    paint_dial(canvas)
    paint_hands(canvas)

    # 收在圆角方形内
    canvas.putalpha(ImageChops.multiply(canvas.getchannel("A"), container))
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
