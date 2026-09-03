#!/usr/bin/env python3
"""自动生成 WBMemoryMigrator.app 的 AppIcon.icns（macOS squircle 圆角）。"""
from PIL import Image, ImageDraw
import os
import subprocess

SIZE = 1024
R = int(SIZE * 0.225)
BG = "#1E293B"      # 深蓝灰背景
CLOUD = (255, 255, 255, 235)
ARROW = "#38BDF8"   # 亮蓝箭头

def draw_icon(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # 背景圆角矩形（四角透明 → macOS 自动套标准 squircle）
    draw.rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * 0.225), fill=BG)

    # 云朵：用几个椭圆 + 矩形底拼成
    s = size
    cy = int(s * 0.46)
    draw.ellipse([int(s*0.28), cy-int(s*0.13), int(s*0.52), cy+int(s*0.13)], fill=CLOUD)
    draw.ellipse([int(s*0.42), cy-int(s*0.17), int(s*0.66), cy+int(s*0.13)], fill=CLOUD)
    draw.ellipse([int(s*0.56), cy-int(s*0.13), int(s*0.80), cy+int(s*0.13)], fill=CLOUD)
    draw.rounded_rectangle([int(s*0.30), cy, int(s*0.78), cy+int(s*0.13)],
                           radius=int(s*0.06), fill=CLOUD)

    # 向下箭头（备份/导入意象）
    ax = s // 2
    ay_top = int(s * 0.58)
    ay_bot = int(s * 0.78)
    aw = int(s * 0.07)      # 箭头杆半宽
    draw.polygon([
        (ax - aw, ay_top),
        (ax + aw, ay_top),
        (ax + aw, ay_bot - int(s*0.08)),
        (ax + int(s*0.12), ay_bot - int(s*0.08)),
        (ax, ay_bot),
        (ax - int(s*0.12), ay_bot - int(s*0.08)),
        (ax - aw, ay_bot - int(s*0.08)),
    ], fill=ARROW)

    return img

def main():
    base = os.path.dirname(os.path.abspath(__file__))
    iconset = os.path.join(base, "AppIcon.iconset")
    icns = os.path.join(base, "AppIcon.icns")

    os.makedirs(iconset, exist_ok=True)
    # 先生成 1024
    big = draw_icon(SIZE)
    big_path = os.path.join(iconset, "icon_512x512@2x.png")
    big.save(big_path)

    sizes = [
        (512, "icon_512x512.png"),
        (256, "icon_256x256.png"),
        (128, "icon_128x128.png"),
        (64,  "icon_32x32@2x.png"),
        (32,  "icon_32x32.png"),
        (16,  "icon_16x16.png"),
    ]
    for px, name in sizes:
        resized = big.resize((px, px), Image.Resampling.LANCZOS)
        # 16x16 也生成 @2x 对应 32
        resized.save(os.path.join(iconset, name))

    # 16x16@2x = 32x32
    big.resize((32, 32), Image.Resampling.LANCZOS).save(
        os.path.join(iconset, "icon_16x16@2x.png"))

    # 128x128@2x = 256x256
    big.resize((256, 256), Image.Resampling.LANCZOS).save(
        os.path.join(iconset, "icon_128x128@2x.png"))

    # 256x256@2x = 512x512
    big.resize((512, 512), Image.Resampling.LANCZOS).save(
        os.path.join(iconset, "icon_256x256@2x.png"))

    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    print(f"Generated {icns}")

if __name__ == "__main__":
    main()
