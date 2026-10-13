# -*- coding: utf-8 -*-
"""
gen_anim.py —— 重建动画帧清单 internalreactionoverlay_frames.lua
               （集成 256×256 自动缩放，原 resize_256.py 功能）
====================================================================================

功能:
  1. 扫描 resources/gfx/overlay_anim/ 下所有子文件夹的 PNG 帧 + 根目录单帧 PNG
  2. 【自动缩放】检测到非 256×256 的 PNG 帧时，原位缩放【覆盖】原文件
     (交互运行：按 y/回车 即缩放，n 跳过；脚本/非交互运行自动缩放)
  3. 过滤 Discord 附件重复帧（文件名带 " #数字" 后缀，如 "xxx_000 #50548.png"）
  4. 重新生成 internalreactionoverlay_frames.lua

用法 (PowerShell):
  本脚本应放在模组根目录（与 main.lua 同级）。模组目录名含空格，
  直接写完整路径时【必须加引号】，否则 PowerShell 会把路径拆开导致报错
  (can't open file)：

    ✗ python D:/.../InternalReactionOverlay+ 内置反应桌宠+/gen_anim.py   ← 会报错
    ✓ cd 'D:/.../InternalReactionOverlay+ 内置反应桌宠+'; python gen_anim.py
    ✓ python 'D:/.../InternalReactionOverlay+ 内置反应桌宠+/gen_anim.py'

参数 (可选):
    python gen_anim.py [mod根目录] [--mode cover|stretch|contain] [--size 256] [--yes]

    --mode   缩放方式:
               contain  等比缩放后补透明边 (不变形, 不裁切, 画面变小, 默认)
               cover    居中裁剪成正方形再缩放 (不变形, 裁掉边缘)
               stretch  直接拉伸成正方形 (可能变形)
    --size   目标边长 (默认 256)
    --yes    检测到非目标尺寸时自动缩放, 不询问 (脚本/自动化用)

依赖: Pillow (仅缩放功能需要; 未安装时自动跳过缩放并警告, 帧清单照常生成)
      安装: pip install pillow
"""
import os
import re
import sys

try:
    from PIL import Image, ImageOps, ImageFile, UnidentifiedImageError
    HAVE_PIL = True
except ImportError:  # Pillow 未安装：跳过缩放，只重建帧清单
    HAVE_PIL = False

if HAVE_PIL:
    ImageFile.LOAD_TRUNCATED_IMAGES = True  # 容忍轻微损坏的图片

# Discord 附件重复帧后缀：如 "stream_cho_grgr_000 #50548.png"
DISCORD_SUFFIX = re.compile(r"\s+#\d+")


def find_mod_root(start):
    """从 start 开始向上查找 mod 根目录（含 main.lua 与 resources/gfx/overlay_anim）。"""
    d = os.path.abspath(start)
    while True:
        if (os.path.isfile(os.path.join(d, "main.lua"))
                and os.path.isdir(os.path.join(d, "resources", "gfx", "overlay_anim"))):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def resolve_root(args):
    # 1) 显式参数：python gen_anim.py <mod根目录>（路径含空格时请加引号）
    if args.root:
        p = os.path.abspath(args.root)
        if os.path.isdir(p):
            return p
        print("警告：忽略非目录参数：%s" % args.root)
    # 2) 脚本所在目录（常规：脚本放在 mod 根目录），并向上查找兜底
    root = find_mod_root(os.path.dirname(os.path.abspath(__file__)))
    if root:
        return root
    # 3) 当前工作目录兜底
    return find_mod_root(os.getcwd())


def clean_png_list(pngs):
    """按基础名（去掉 Discord ' #数字' 后缀）分组，每组优先保留不带后缀的干净文件。"""
    groups = {}
    for f in pngs:
        base = DISCORD_SUFFIX.sub("", f)
        groups.setdefault(base, []).append(f)
    picked = []
    for base, cands in groups.items():
        clean = [c for c in cands if not DISCORD_SUFFIX.search(c)]
        picked.append(sorted(clean if clean else cands)[0])
    return sorted(picked)   # 显式按文件名排序，保证帧序稳定（000,001,002…）


def load_image(path):
    """打开图片并按 EXIF 校正方向；统一为可安全保存 PNG 的模式，尽量保留透明通道。"""
    img = Image.open(path)
    img = ImageOps.exif_transpose(img)
    if img.mode == 'P':
        img = img.convert('RGBA')
    elif img.mode not in ('RGB', 'RGBA', 'L'):
        img = img.convert('RGB')
    return img


def resize_square(img, size, mode):
    """按指定模式缩放为 size×size。"""
    w, h = img.size
    if mode == 'stretch':
        return img.resize((size, size), Image.LANCZOS)
    if mode == 'cover':  # 居中裁剪成正方形 -> 缩放
        s = min(w, h)
        left, top = (w - s) // 2, (h - s) // 2
        return img.crop((left, top, left + s, top + s)).resize((size, size), Image.LANCZOS)
    if mode == 'contain':  # 等比缩放 -> 居中补透明边
        img.thumbnail((size, size), Image.LANCZOS)
        has_alpha = img.mode == 'RGBA'
        bg_color = (255, 255, 255, 0) if has_alpha else (255, 255, 255)
        canvas = Image.new('RGBA' if has_alpha else 'RGB', (size, size), bg_color)
        canvas.paste(img, ((size - img.width) // 2, (size - img.height) // 2))
        return canvas
    raise ValueError('未知模式: %s' % mode)


def collect_frames(root):
    """扫描全部动画帧，返回 [(动画键, 资源相对路径, 绝对路径)]，已去重 Discord 重复帧。"""
    ANIM = os.path.join(root, "resources", "gfx", "overlay_anim")
    KEY_MAP = {"voice_training": "activity"}  # 旧目录名兼容
    ROOT_KEY_MAP = {"main.png": "main_static", "death.png": "death_static"}

    frames = []
    # 根目录独立 PNG（单帧动画）：main.png -> main_static；其余 <name>.png -> <name>
    for fn in sorted(os.listdir(ANIM)):
        full = os.path.join(ANIM, fn)
        if os.path.isfile(full) and fn.lower().endswith(".png"):
            key = ROOT_KEY_MAP.get(fn.lower(), os.path.splitext(fn)[0])
            frames.append((key, "gfx/overlay_anim/" + fn, full))
    # 子文件夹：每帧一张 PNG
    for d in sorted(os.listdir(ANIM)):
        full = os.path.join(ANIM, d)
        if not os.path.isdir(full):
            continue
        key = KEY_MAP.get(d, d)
        pngs = clean_png_list(f for f in os.listdir(full) if f.lower().endswith(".png"))
        for f in pngs:
            frames.append((key, "gfx/overlay_anim/" + d + "/" + f, os.path.join(full, f)))
    return frames


def check_and_resize(frames, size, mode, auto_yes):
    """检测非 size×size 的 PNG 帧；提示确认后原位缩放覆盖。返回 (检测数, 成功数, 失败数)。"""
    bad = []  # [(资源相对路径, 绝对路径, 实际尺寸)]
    for key, rel, full in frames:
        try:
            with Image.open(full) as img:
                w, h = img.size
            if (w, h) != (size, size):
                bad.append((rel, full, "%dx%d" % (w, h)))
        except UnidentifiedImageError:
            print("  [!] 无法识别的图片，跳过: %s" % rel)
        except Exception as e:
            print("  [!] 读取尺寸失败 %s: %s" % (rel, e))

    if not bad:
        return 0, 0, 0

    print("=" * 60)
    print("检测到 %d 个非 %d×%d 的动画帧（将【覆盖原文件】）:" % (len(bad), size, size))
    for rel, full, dim in bad:
        print("  - %s  (%s)" % (rel, dim))
    print("缩放方式: %s -> %d×%d PNG" % (mode, size, size))

    if not auto_yes:
        try:
            ans = input("是否将这些帧缩放为 %d×%d 并覆盖原文件？(y/回车=缩放, n=跳过): "
                        % (size, size)).strip().lower()
        except EOFError:
            ans = "y"  # 非交互环境（脚本/双击运行）：无法询问，按目标自动缩放
        if ans not in ("y", "yes", ""):
            print("已跳过缩放，原文件未改动（帧清单照常生成）。")
            return len(bad), 0, 0

    ok, failed = 0, 0
    for rel, full, dim in bad:
        try:
            img = load_image(full)
            img = resize_square(img, size, mode)
            img.save(full, 'PNG', optimize=True)
            print("  [OK] %s  %s -> %d×%d" % (rel, dim, size, size))
            ok += 1
        except Exception as e:
            print("  [!] 转换失败 %s: %s" % (rel, e))
            failed += 1
    return len(bad), ok, failed


def verify_all_square(frames, size):
    """校验所有会被写入帧清单的帧都是 size×size；返回不满足的（资源相对路径）。"""
    bad = []
    for key, rel, full in frames:
        try:
            with Image.open(full) as img:
                if img.size != (size, size):
                    bad.append(rel)
        except Exception:
            bad.append(rel)
    return bad


def lua_str_list(items):
    body = "".join('        "%s",\n' % i for i in items)
    return "{\n" + body + "    }"


def main():
    # Windows 控制台可能是 GBK，强制 UTF-8 输出避免中文乱码
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding='utf-8', errors='replace')
        except Exception:
            pass

    import argparse
    parser = argparse.ArgumentParser(
        description="重建 InternalReactionOverlay 帧清单（可选自动缩放 256×256）")
    parser.add_argument("root", nargs="?", default=None,
                        help="模组根目录（缺省自动定位；路径含空格时请加引号）")
    parser.add_argument("--mode", choices=("stretch", "cover", "contain"), default="contain",
                        help="缩放方式 (默认 contain=等比+透明边)")
    parser.add_argument("--size", type=int, default=256, help="目标边长 (默认 256)")
    parser.add_argument("--yes", action="store_true",
                        help="检测到非目标尺寸时自动缩放，不询问")
    args = parser.parse_args()

    root = resolve_root(args)
    if not root:
        print("=" * 70)
        print("错误：找不到动画目录 resources/gfx/overlay_anim。")
        print("请确认脚本放在模组根目录（与 main.lua 同级），或指定模组根目录：")
        print("    python gen_anim.py 'D:/path/to/InternalReactionOverlay+ 内置反应桌宠+'")
        print("（PowerShell 中路径含空格时必须加引号，否则会报 can't open file）")
        print("=" * 70)
        return 1

    ANIM = os.path.join(root, "resources", "gfx", "overlay_anim")
    if not os.path.isdir(ANIM):
        print("错误：找不到动画帧目录：%s" % ANIM)
        return 1

    frames = collect_frames(root)
    if not frames:
        print("错误：overlay_anim 下没有找到任何 PNG 帧。")
        return 1

    # 缩放（交互运行按 y/回车 缩放；脚本/非交互运行自动缩放；Pillow 未安装则跳过）
    if HAVE_PIL:
        check_and_resize(frames, args.size, args.mode, args.yes)
        # 校验：所有会被使用的帧都应为目标尺寸，否则游戏内可能不显示
        leftover = verify_all_square(frames, args.size)
        if leftover:
            print("=" * 60)
            print("[!] 警告：仍有 %d 个帧不是 %d×%d（未安装 Pillow 或选择跳过缩放），"
                  "游戏内这些动画可能无法显示：" % (len(leftover), args.size, args.size))
            for rel in leftover:
                print("  - %s" % rel)
            print("=" * 60)
        else:
            print("校验通过：全部 %d 个动画帧均为 %d×%d，可直接进游戏使用。"
                  % (len(frames), args.size, args.size))
    else:
        print("[!] 未安装 Pillow，跳过 256×256 自动缩放。")
        print("    如需该功能请安装: pip install pillow")

    # 生成帧清单
    grouped = {}
    for key, rel, full in frames:
        grouped.setdefault(key, []).append(rel)

    FRAMES_LUA = os.path.join(root, "internalreactionoverlay_frames.lua")
    lines = [
        "-- 自动生成：动画帧清单（扫描 resources/gfx/overlay_anim/）",
        "-- 由 gen_anim.py 生成；新增/替换帧后重新运行 python gen_anim.py",
        '-- 已过滤 Discord 附件重复帧（文件名带 " #数字" 后缀）',
        "",
        "return {",
    ]
    for key in sorted(grouped):
        lines.append("    %s = %s," % (key, lua_str_list(grouped[key])))
    lines.append("}")

    with open(FRAMES_LUA, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    print("internalreactionoverlay_frames.lua 已重建(%d 个动画):" % len(grouped))
    for key in sorted(grouped):
        print("  %-14s %2d 帧" % (key, len(grouped[key])))
    print("生成位置: %s" % FRAMES_LUA)
    return 0


if __name__ == "__main__":
    sys.exit(main())
