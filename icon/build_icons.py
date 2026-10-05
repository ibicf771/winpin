#!/usr/bin/env python3
"""winpin 应用图标后期管线
AI 原图 -> 去水印 -> 去内嵌圆角 -> Apple macOS 图标网格 -> 全尺寸导出 + icns
网格规范：1024 画布 / 824x824 主体居中(offset 100,100) / 圆角半径 185.4
"""
import os, shutil, subprocess
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(ROOT, "raw")
SRC = os.path.join(ROOT, "source")
MASTER = os.path.join(ROOT, "master")
ISET = os.path.join(ROOT, "iconset")
ICNS = os.path.join(ROOT, "icns")
PREVIEW = os.path.join(ROOT, "preview")
for d in (SRC, MASTER, ISET, ICNS, PREVIEW):
    os.makedirs(d, exist_ok=True)

CANVAS = 1024
BODY = 824
OFFSET = (CANVAS - BODY) // 2   # 100
RADIUS = 185.4

IMAGES = {
    "A": "Flat_vector_macOS_app_icon_art_2026-10-05T02-16-23.png",       # 主版：居中图钉 + 层叠窗口
    "B": "macOS_app_icon_artwork__thin_l_2026-10-05T02-15-02.png",       # 线条风格
    "C": "macOS_app_icon_artwork__glossy_2026-10-05T02-15-02.png",       # 渐变拟物
}


def remove_watermark(img):
    """右下角水印区域用其左侧的干净背景水平镜像回填（仅在远离水印的边缘羽化）"""
    a = np.asarray(img).astype(np.float64)
    x0, y0 = 876, 936                  # 回填区域，须完整盖住水印 (bbox 约 x903-1013 / y963-1013)
    w, h = CANVAS - x0, CANVAS - y0
    src = a[y0:CANVAS, x0 - w:x0]      # 水印左侧的干净背景
    patch = src[:, ::-1]               # 以 x=x0 为轴水平镜像
    alpha = np.ones((h, w))
    alpha = np.minimum(alpha, np.clip(np.arange(w) / 10.0, 0, 1)[None, :])
    alpha = np.minimum(alpha, np.clip(np.arange(h) / 10.0, 0, 1)[:, None])
    roi = a[y0:CANVAS, x0:CANVAS]
    a[y0:CANVAS, x0:CANVAS] = patch * alpha[..., None] + roi * (1 - alpha[..., None])
    return Image.fromarray(a.round().clip(0, 255).astype(np.uint8))


def detect_inset(a):
    """检测模型是否画了内嵌圆角框；返回需内缩的像素数"""
    corners = [a[3, 3], a[3, -4], a[-4, 3], a[-4, -4]]
    if not all(np.abs(c - 255).max() < 12 for c in corners):
        return 2                       # 四角非纯白 => 全出血，无内嵌框
    # 内嵌框圆角半径 = 顶边第一个非白像素的 x 坐标
    d = 255 - a.min(axis=2)
    mask = d > 14
    xs = [int(np.where(mask[y])[0].min()) for y in (1, 2, 3) if mask[y].any()]
    r = max(xs) if xs else 40
    return min(120, max(48, r + 14))


def squircle_mask(size):
    """Apple 官方网格圆角（body 尺寸 / 半径 185.4）"""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=round(RADIUS * size / BODY), fill=255)
    return m


def build_master(img, tag):
    a = np.asarray(img.convert("RGB")).astype(int)
    inset = detect_inset(a)
    crop = img.crop((inset, inset, CANVAS - inset, CANVAS - inset))
    body = crop.resize((BODY, BODY), Image.LANCZOS)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(body, (OFFSET, OFFSET), squircle_mask(BODY))
    master = os.path.join(MASTER, f"winpin-icon-{tag}-macos-1024.png")
    canvas.save(master)
    print(f"  [{tag}] inset={inset}  master -> {os.path.relpath(master, ROOT)}")
    return canvas


SIZES = [16, 32, 128, 256, 512]   # Apple 标准 iconset 命名，@2x 自动补 32/64/256/512/1024


def export_sizes(master, tag):
    iset = os.path.join(ISET, f"winpin-{tag}.iconset")
    if os.path.exists(iset):
        shutil.rmtree(iset)
    os.makedirs(iset)
    for s in SIZES:
        im = master.resize((s, s), Image.LANCZOS)
        if s <= 64:
            im = im.filter(ImageFilter.UnsharpMask(radius=0.6, percent=60, threshold=2))
        im.save(os.path.join(iset, f"icon_{s}x{s}.png"))
        if s < 1024:
            im.resize((s * 2, s * 2), Image.LANCZOS).save(os.path.join(iset, f"icon_{s}x{s}@2x.png"))
    out = os.path.join(ICNS, f"winpin-{tag}.icns")
    subprocess.run(["iconutil", "-c", "icns", iset, "-o", out], check=True)
    print(f"  [{tag}] iconset({len(SIZES)*2 - 1} 个尺寸) + icns -> {os.path.relpath(out, ROOT)}")


def main():
    masters = {}
    for tag, fname in IMAGES.items():
        p = os.path.join(RAW, fname)
        print(f"处理 {tag}: {fname}")
        img = remove_watermark(Image.open(p))
        img.save(os.path.join(SRC, f"winpin-icon-{tag}-source.png"))
        m = build_master(img, tag)
        export_sizes(m, tag)
        masters[tag] = m
    print("\n完成")


if __name__ == "__main__":
    main()
