#!/usr/bin/env python3
"""把一张图做成 macOS app 图标资源。

裁剪逻辑照搬 My-Orphies (app-customize-card.tsx)：
  Dock 图标：1024 画布，squircle body 占 824/1024 ≈ 80.5%，四周透明
             padding ~100px，圆角半径 = body 边长 × 22.5%
  Tray 图标：中心裁正方形、填满画布、不 padding 不圆角（菜单栏图标贴边渲染）

用法:
  python3 scripts/make-icon.py dock  <源图> <输出 appiconset 目录>
  python3 scripts/make-icon.py tray  <源图> <输出 imageset 目录>
"""
import sys, os, json
from PIL import Image, ImageDraw

CANVAS = 1024
BODY_RATIO = 824 / 1024
CORNER_RATIO = 0.225  # 占 body 边长
TRAY_SIZE = 128

def center_square(img: Image.Image) -> Image.Image:
    side = min(img.width, img.height)
    sx = (img.width - side) // 2
    sy = (img.height - side) // 2
    return img.crop((sx, sy, sx + side, sy + side))

def make_dock_master(src_path: str) -> Image.Image:
    img = center_square(Image.open(src_path).convert("RGBA"))
    body = round(CANVAS * BODY_RATIO)
    offset = (CANVAS - body) // 2
    radius = round(body * CORNER_RATIO)
    body_img = img.resize((body, body), Image.LANCZOS)
    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, body - 1, body - 1], radius=radius, fill=255
    )
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(body_img, (offset, offset), mask)
    return canvas

def build_dock(src: str, out: str):
    os.makedirs(out, exist_ok=True)
    master = make_dock_master(src)
    specs = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),
             (256,1),(256,2),(512,1),(512,2)]
    images, seen = [], {}
    for size, scale in specs:
        px = size * scale
        if px not in seen:
            master.resize((px, px), Image.LANCZOS).save(
                os.path.join(out, f"icon_{px}.png"))
            seen[px] = f"icon_{px}.png"
        images.append({"size": f"{size}x{size}", "idiom": "mac",
                        "filename": seen[px], "scale": f"{scale}x"})
    with open(os.path.join(out, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"version": 1, "author": "xcode"}},
                  f, indent=2)
    print(f"dock: wrote {len(seen)} PNGs + Contents.json -> {out}")

def build_tray(src: str, out: str):
    """菜单栏 imageset：中心裁正方形、填满、不圆角、保留透明。
    出 1x/2x/3x 三档，菜单栏在不同缩放下都清晰。"""
    os.makedirs(out, exist_ok=True)
    img = center_square(Image.open(src_path := src).convert("RGBA"))
    images = []
    for scale in (1, 2, 3):
        px = TRAY_SIZE * scale // 4   # 1x=32, 2x=64, 3x=96 —— 菜单栏小图标够用
        fname = f"tray_{scale}x.png"
        img.resize((px, px), Image.LANCZOS).save(os.path.join(out, fname))
        images.append({"idiom": "mac", "filename": fname, "scale": f"{scale}x"})
    with open(os.path.join(out, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"version": 1, "author": "xcode"}},
                  f, indent=2)
    print(f"tray: wrote 3 PNGs + Contents.json -> {out}")

def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("dock", "tray"):
        print("usage: make-icon.py {dock|tray} <src> <out-dir>")
        sys.exit(1)
    mode, src, out = sys.argv[1], sys.argv[2], sys.argv[3]
    (build_dock if mode == "dock" else build_tray)(src, out)

if __name__ == "__main__":
    main()
