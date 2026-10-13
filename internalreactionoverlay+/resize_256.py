# -*- coding: utf-8 -*-
"""
resize_256.py — 把所选文件夹(含所有子文件夹)下的所有图片缩放为 256×256 的 PNG
================================================================================
用法 (PowerShell):
    python resize_256.py                          # 弹窗选择文件夹
    python resize_256.py D:\some\pics             # 直接指定文件夹
    python resize_256.py D:\some\pics D:\out -Mode cover

行为:
    - 递归处理所选文件夹及其所有子文件夹里的图片 (jpg/jpeg/png/webp/bmp/gif/tiff 等)
    - 输出到输出目录, 完整保留原文件夹结构; 原图一律不动
    - 输出目录缺省为 <所选文件夹>/resized_256, 该子目录会被自动跳过,
      不会被当成素材重复加工

参数:
    input    输入文件夹, 缺省时弹窗选择
    output   输出目录, 缺省为 <input>/resized_256
    -Mode    stretch | cover | contain   (默认 stretch)
                 stretch  直接拉伸成正方形 (可能变形)
                 cover    居中裁剪成正方形再缩放 (不变形, 裁掉多余边缘)
                 contain  等比缩放后补白边 (不变形, 不裁切)
    -Size    输出边长, 默认 256

依赖: Pillow  (安装: pip install pillow)
"""

import os
import sys
import argparse
from pathlib import Path
from PIL import Image, ImageOps, ImageFile, UnidentifiedImageError

ImageFile.LOAD_TRUNCATED_IMAGES = True  # 容忍轻微损坏的图片

IMAGE_EXTS = {'.jpg', '.jpeg', '.jfif', '.png', '.webp', '.bmp', '.gif', '.tif', '.tiff'}
OUTPUT_DIR_NAME = 'resized_256'


def pick_directory() -> str | None:
    """弹出系统目录选择框, 让用户选择文件夹."""
    import tkinter as tk
    from tkinter import filedialog

    root = tk.Tk()
    root.withdraw()
    root.attributes('-topmost', True)
    try:
        return filedialog.askdirectory(title='选择包含图片的文件夹')
    finally:
        root.destroy()


def load_image(path: Path) -> Image.Image:
    """打开图片并按 EXIF 校正方向."""
    img = Image.open(path)
    img = ImageOps.exif_transpose(img)
    # 统一成可安全保存 PNG 的模式, 尽量保留透明通道
    if img.mode == 'P':
        img = img.convert('RGBA')
    elif img.mode not in ('RGB', 'RGBA', 'L'):
        img = img.convert('RGB')
    return img


def resize_square(img: Image.Image, size: int, mode: str) -> Image.Image:
    """按指定模式缩放为 size×size."""
    w, h = img.size
    if mode == 'stretch':
        return img.resize((size, size), Image.LANCZOS)

    if mode == 'cover':  # 居中裁剪成正方形 → 缩放
        s = min(w, h)
        left, top = (w - s) // 2, (h - s) // 2
        return img.crop((left, top, left + s, top + s)).resize((size, size), Image.LANCZOS)

    if mode == 'contain':  # 等比缩放 → 居中补边
        img.thumbnail((size, size), Image.LANCZOS)
        has_alpha = img.mode == 'RGBA'
        bg_color = (255, 255, 255, 0) if has_alpha else (255, 255, 255)
        canvas = Image.new('RGBA' if has_alpha else 'RGB', (size, size), bg_color)
        canvas.paste(img, ((size - img.width) // 2, (size - img.height) // 2))
        return canvas

    raise ValueError(f'未知模式: {mode}')


def open_image_with_retry(path: str, attempts: int = 2, delay: float = 0.5) -> Image.Image:
    """
    打开图片; 若因文件正在复制/同步/被占用而瞬间不可用, 稍等重试一次.
    """
    import time
    for i in range(attempts):
        try:
            return load_image(Path(path))
        except FileNotFoundError:
            if i + 1 < attempts:
                time.sleep(delay)
            else:
                raise


def collect_images(input_dir: str, output_dir: str) -> list[tuple[str, str]]:
    """
    递归收集图片, 返回 [(源文件绝对路径, 相对输入目录的父目录)].
    父目录为 '' 表示输入目录根; 同时跳过输出目录本身.
    跟随目录符号链接/联接(junction), 并用真实路径去重防止死循环.
    """
    input_abs = os.path.abspath(input_dir)
    output_abs = os.path.abspath(output_dir)
    items: list[tuple[str, str]] = []
    visited: set = set()
    for root, dirs, files in os.walk(input_abs, followlinks=True):
        # 已访问过的真实路径 -> 链接回环, 剪掉不再深入
        try:
            real_root = os.path.realpath(root)
        except OSError:
            real_root = root
        if real_root in visited:
            dirs[:] = []
            continue
        visited.add(real_root)
        # 跳过输出目录, 防止把上一次的产物再加工一遍
        dirs[:] = [d for d in dirs
                   if os.path.abspath(os.path.join(root, d)) != output_abs]
        rel = os.path.relpath(root, input_abs)
        if rel == '.':
            rel = ''
        for fn in sorted(files):
            if os.path.splitext(fn)[1].lower() in IMAGE_EXTS:
                items.append((os.path.join(root, fn), rel))
    return items


def unique_dst(output_dir: Path, rel: str, stem: str, used: set) -> Path:
    """
    生成输出路径; 同一目录下若出现同名冲突 (如 a.jpg 与 a.png),
    自动追加 _1, _2 ... 后缀, 避免互相覆盖.
    """
    base = output_dir / rel / f'{stem}.png'
    if str(base) not in used:
        used.add(str(base))
        return base
    i = 1
    while True:
        cand = output_dir / rel / f'{stem}_{i}.png'
        if str(cand) not in used:
            used.add(str(cand))
            return cand
        i += 1


def main() -> None:
    # Windows 控制台可能是 GBK, 强制 UTF-8 输出避免中文乱码
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding='utf-8', errors='replace')
        except Exception:
            pass

    parser = argparse.ArgumentParser(
        description='将文件夹及其所有子文件夹下的图片缩放为 256×256 的 PNG (原图不动)',
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('input', nargs='?', help='输入文件夹, 缺省时弹窗选择')
    parser.add_argument('output', nargs='?', help='输出目录, 缺省为 <input>/resized_256')
    parser.add_argument('-Mode', choices=('stretch', 'cover', 'contain'), default='stretch',
                        help='缩放方式 (默认 stretch)')
    parser.add_argument('-Size', type=int, default=256, help='输出边长 (默认 256)')
    args = parser.parse_args()

    # 1. 确定输入文件夹
    input_dir = Path(args.input) if args.input else None
    if input_dir is None or not input_dir.is_dir():
        print('请在弹出的窗口中选择文件夹...')
        picked = pick_directory()
        if not picked:
            print('[!] 未选择文件夹, 退出。')
            return
        input_dir = Path(picked)
    if not input_dir.is_dir():
        print(f'[!] 文件夹不存在: {input_dir}')
        return

    # 2. 确定输出目录 (缺省为输入目录下的子文件夹)
    output_dir = Path(args.output) if args.output else input_dir / OUTPUT_DIR_NAME

    # 3. 安全检查: 输出目录不能与输入文件夹完全相同
    #    (默认的 <input>/resized_256 子目录是允许的, 递归收集时会自动跳过它)
    try:
        in_res, out_res = input_dir.resolve(), output_dir.resolve()
    except OSError:
        in_res, out_res = input_dir.absolute(), output_dir.absolute()
    if in_res == out_res:
        print(f'[!] 输出目录不能与输入文件夹相同: {output_dir}')
        print(f'    请用: python resize_256.py "{input_dir}" "D:\\其他输出目录"')
        return

    output_dir.mkdir(parents=True, exist_ok=True)
    size = max(1, args.Size)

    # 4. 递归收集图片
    images = collect_images(str(input_dir), str(output_dir))
    if not images:
        print(f'[!] 文件夹中没有图片: {input_dir}')
        return

    print(f'输入文件夹 : {input_dir}')
    print(f'输出目录   : {output_dir}')
    print(f'目标尺寸   : {size}×{size} PNG  (模式: {args.Mode}, 递归子文件夹: 是)')
    print('-' * 60)

    # 5. 逐张加工 (打开失败与保存失败分开报告, 方便定位问题)
    used: set = set()
    ok, failed = 0, []
    for src, rel in images:
        rel_src = os.path.relpath(src, input_dir)
        try:
            img = open_image_with_retry(src)
        except FileNotFoundError as e:
            failed.append(f'{rel_src} (文件打不开/不存在: {e})')
            continue
        except UnidentifiedImageError:
            failed.append(f'{rel_src} (无法识别的图片格式)')
            continue
        except Exception as e:
            failed.append(f'{rel_src} (打开失败: {e})')
            continue
        try:
            img = resize_square(img, size, args.Mode)
            dst = unique_dst(output_dir, rel, Path(src).stem, used)
            dst.parent.mkdir(parents=True, exist_ok=True)  # 自动创建子文件夹
            img.save(dst, 'PNG', optimize=True)
            print(f'  [OK] {rel_src}  ->  {os.path.relpath(dst, output_dir)}')
            ok += 1
        except Exception as e:
            failed.append(f'{rel_src} (保存失败: {e})')

    print('=' * 60)
    print(f'完成: 成功 {ok} 张, 失败 {len(failed)} 张。')
    if failed:
        print('失败清单:')
        for f in failed:
            print(f'  - {f}')
    print(f'输出位置: {output_dir}')
    print(f'输出目录已按原文件夹结构整理: 每个子文件夹对应一个同名输出子文件夹。')


if __name__ == '__main__':
    main()
