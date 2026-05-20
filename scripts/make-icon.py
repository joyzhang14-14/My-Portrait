#!/usr/bin/env python3
"""把一张图做成 macOS AppIcon.appiconset。

裁剪逻辑照搬 My-Orphies (app-customize-card.tsx)：
  - 1024 画布，squircle body 占 824/1024 ≈ 80.5%，四周透明 padding ~100px
  - 圆角半径 = body 边长 × 22.5%
  - 源图先中心裁成正方形，再画进 body 区域，圆角矩形 clip

用法: python3 scripts/make-icon.py <源图> <输出 appiconset 目录>
"""
import sys, os, json
from PIL import Image, ImageDraw

CANVAS = 1024
BODY_RATIO = 824 / 1024
CORNER_RATIO = 0.225  # 占 body 边长

def make_master(src_path: str) -> Image.Image:
    img = Image.open(src_path).convert("RGBA")
    # 1) 中心裁正方形（短边）
    side = min(img.width, img.height)
    sx = (img.width - side) // 2
    sy = (img.height - side) // 2
    img = img.crop((sx, sy, sx + side, sy + side))

    # 2) body 区域
    body = round(CANVAS * BODY_RATIO)
    offset = (CANVAS - body) // 2
    radius = round(body * CORNER_RATIO)

    body_img = img.resize((body, body), Image.LANCZOS)

    # 3) 圆角矩形 mask
    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, body - 1, body - 1], radius=radius, fill=255
    )

    # 4) 贴到透明画布
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(body_img, (offset, offset), mask)
    return canvas

def main():
    if len(sys.argv) != 3:
        print("usage: make-icon.py <src> <appiconset-dir>")
        sys.exit(1)
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    master = make_master(src)

    # macOS AppIcon 需要的 (size, scale) 组合
    specs = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),
             (256,1),(256,2),(512,1),(512,2)]
    images = []
    seen = {}
    for size, scale in specs:
        px = size * scale
        if px not in seen:
            im = master.resize((px, px), Image.LANCZOS)
            fname = f"icon_{px}.png"
            im.save(os.path.join(out, fname))
            seen[px] = fname
        images.append({
            "size": f"{size}x{size}",
            "idiom": "mac",
            "filename": seen[px],
            "scale": f"{scale}x",
        })

    with open(os.path.join(out, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"version": 1, "author": "xcode"}},
                  f, indent=2)
    print(f"wrote {len(seen)} PNGs + Contents.json -> {out}")

if __name__ == "__main__":
    main()
