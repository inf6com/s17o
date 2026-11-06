#!/usr/bin/env python3
"""
gen_icon.py — s17o 共通アイコン生成スクリプト

ソース: s17o/Assets.xcassets/AppIcon.appiconset/icon_256x256.png
出力:  windows/s17o/Resources/icon.ico

使い方:
    pip install pillow
    python3 tools/gen_icon.py
"""

import io
import struct
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC_PNG = REPO_ROOT / "s17o/Assets.xcassets/AppIcon.appiconset/icon_256x256.png"
DST_ICO = REPO_ROOT / "windows/s17o/Resources/icon.ico"
SIZES = [16, 32, 48, 64, 128, 256]


def main() -> None:
    try:
        from PIL import Image
    except ImportError:
        print("Pillow が必要です: pip install pillow", file=sys.stderr)
        sys.exit(1)

    if not SRC_PNG.exists():
        print(f"ソース PNG が見つかりません: {SRC_PNG}", file=sys.stderr)
        sys.exit(1)

    DST_ICO.parent.mkdir(parents=True, exist_ok=True)

    img = Image.open(SRC_PNG).convert("RGBA")
    images: list[bytes] = []
    for size in SIZES:
        resized = img.resize((size, size), Image.LANCZOS)
        buf = io.BytesIO()
        resized.save(buf, format="PNG")
        images.append(buf.getvalue())

    count = len(images)
    header = struct.pack("<HHH", 0, 1, count)
    dir_offset = 6 + count * 16
    entries = b""
    data = b""
    for i, png_data in enumerate(images):
        size = SIZES[i]
        w = size if size < 256 else 0
        h = size if size < 256 else 0
        entry = struct.pack("<BBBBHHII", w, h, 0, 0, 1, 32,
                            len(png_data), dir_offset + len(data))
        entries += entry
        data += png_data

    DST_ICO.write_bytes(header + entries + data)
    print(f"生成完了: {DST_ICO}")


if __name__ == "__main__":
    main()
