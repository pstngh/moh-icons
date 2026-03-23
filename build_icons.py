#!/usr/bin/env python3
"""
Build standard-compliant .ico (Windows) and .icns (macOS) icon files from SVG sources.

Windows .ICO specification (Microsoft Learn):
  - Required sizes: 16, 24, 32, 48, 256 (bare minimum per Microsoft)
  - Additional DPI scale sizes: 20, 30, 36, 40, 60, 64, 72, 80, 96
  - Sizes <= 48px: stored as 32-bit BMP with AND mask
  - Size 256px: stored as PNG-compressed (Microsoft requirement)
  - All entries use 32-bit ARGB (true color + alpha)
  Reference: https://learn.microsoft.com/en-us/windows/apps/design/iconography/app-icon-construction

macOS .ICNS specification (Apple):
  - OSType ic07: 128x128
  - OSType ic08: 256x256
  - OSType ic09: 512x512
  - OSType ic10: 1024x1024 (512x512@2x, required for App Store)
  - OSType ic11: 32x32   (16x16@2x)
  - OSType ic12: 64x64   (32x32@2x)
  - OSType ic13: 256x256  (128x128@2x)
  - OSType ic14: 512x512  (256x256@2x)
  - All entries stored as PNG
  Reference: https://developer.apple.com/design/human-interface-guidelines/app-icons
"""

import io
import os
import struct
import sys
from pathlib import Path

import cairosvg
from PIL import Image

# ---------------------------------------------------------------------------
# Windows ICO sizes per Microsoft specification
# https://learn.microsoft.com/en-us/windows/apps/design/iconography/app-icon-construction
#
# Base sizes at 100% scale:
#   16px - context menus, title bar, system tray
#   24px - taskbar, search results, Start all apps list
#   32px - Start pins
#
# Scale factors: 100%, 125%, 150%, 200%, 250%, 300%, 400%
#   16 -> 16, 20, 24, 32, 40, 48, 64
#   24 -> 24, 30, 36, 48, 60, 72, 96
#   32 -> 32, 40, 48, 64, 80, 96, 256
#
# Deduplicated and sorted:
ICO_SIZES = [16, 20, 24, 30, 32, 36, 40, 48, 60, 64, 72, 80, 96, 256]

# Sizes that must use PNG compression in the ICO container (Microsoft requirement)
ICO_PNG_THRESHOLD = 256  # 256x256 must be PNG-compressed

# ---------------------------------------------------------------------------
# macOS ICNS entries per Apple specification
# Each tuple: (ostype_code, pixel_size, description)
ICNS_ENTRIES = [
    (b"ic07", 128,  "128x128"),
    (b"ic08", 256,  "256x256"),
    (b"ic09", 512,  "512x512"),
    (b"ic10", 1024, "1024x1024 (512x512@2x)"),
    (b"ic11", 32,   "32x32 (16x16@2x)"),
    (b"ic12", 64,   "64x64 (32x32@2x)"),
    (b"ic13", 256,  "256x256 (128x128@2x)"),
    (b"ic14", 512,  "512x512 (256x256@2x)"),
]


def svg_to_png(svg_path: str, size: int) -> bytes:
    """Render an SVG to a PNG at the given square size using cairosvg."""
    return cairosvg.svg2png(
        url=svg_path,
        output_width=size,
        output_height=size,
    )


def png_bytes_to_image(png_data: bytes) -> Image.Image:
    """Load PNG bytes into a Pillow Image (RGBA)."""
    return Image.open(io.BytesIO(png_data)).convert("RGBA")


# ---------------------------------------------------------------------------
# ICO file builder — constructs a spec-compliant ICO binary
# ---------------------------------------------------------------------------

def build_bmp_entry(img: Image.Image) -> bytes:
    """
    Build a 32-bit ARGB DIB (Device Independent Bitmap) for an ICO entry.

    ICO BMP format stores a BITMAPINFOHEADER followed by pixel data in
    bottom-up row order with 32-bit BGRA pixels, plus a 1-bit AND mask.

    Per ICO spec, the biHeight field is set to 2x the actual height
    (to account for the XOR + AND masks).
    """
    w, h = img.size

    # BITMAPINFOHEADER (40 bytes)
    header = struct.pack(
        "<IiiHHIIiiII",
        40,          # biSize
        w,           # biWidth
        h * 2,       # biHeight (doubled for XOR + AND masks)
        1,           # biPlanes
        32,          # biBitCount (32-bit ARGB)
        0,           # biCompression (BI_RGB)
        0,           # biSizeImage (can be 0 for BI_RGB)
        0,           # biXPelsPerMeter
        0,           # biYPelsPerMeter
        0,           # biClrUsed
        0,           # biClrImportant
    )

    # XOR mask: 32-bit BGRA pixel data, bottom-up row order
    pixels = img.load()
    xor_rows = []
    for y in range(h - 1, -1, -1):  # bottom to top
        row = bytearray()
        for x in range(w):
            r, g, b, a = pixels[x, y]
            row.extend([b, g, r, a])  # BGRA order
        xor_rows.append(bytes(row))
    xor_mask = b"".join(xor_rows)

    # AND mask: 1-bit transparency mask, bottom-up, rows padded to 4-byte boundary
    and_row_bytes = (w + 7) // 8
    and_row_padded = ((and_row_bytes + 3) // 4) * 4
    and_rows = []
    for y in range(h - 1, -1, -1):
        row = bytearray(and_row_padded)
        for x in range(w):
            r, g, b, a = pixels[x, y]
            if a == 0:  # fully transparent -> AND bit = 1
                row[x // 8] |= (0x80 >> (x % 8))
        and_rows.append(bytes(row))
    and_mask = b"".join(and_rows)

    return header + xor_mask + and_mask


def build_ico(images: list[tuple[int, Image.Image, bytes]]) -> bytes:
    """
    Build a complete ICO file from a list of (size, pil_image, png_bytes) tuples.

    ICO file structure:
      - ICONDIR header (6 bytes)
      - ICONDIRENTRY array (16 bytes each)
      - Image data blocks

    Sizes <= 48px use BMP format. Size 256px uses PNG compression.
    """
    num_images = len(images)

    # ICONDIR header
    header = struct.pack("<HHH",
        0,             # idReserved (must be 0)
        1,             # idType (1 = ICO)
        num_images,    # idCount
    )

    # Build image data blocks and directory entries
    entries_data = []
    image_blobs = []

    # Calculate offset: header (6) + entries (16 * n)
    data_offset = 6 + 16 * num_images

    for size, pil_img, png_data in images:
        if size >= ICO_PNG_THRESHOLD:
            # PNG compression for 256x256 (Microsoft requirement)
            blob = png_data
        else:
            # BMP format for smaller sizes
            blob = build_bmp_entry(pil_img)

        # Width/Height: 0 means 256 in ICO spec
        w = 0 if size >= 256 else size
        h = 0 if size >= 256 else size

        entry = struct.pack("<BBBBHHII",
            w,             # bWidth
            h,             # bHeight
            0,             # bColorCount (0 for >= 8bpp)
            0,             # bReserved
            1,             # wPlanes
            32,            # wBitCount
            len(blob),     # dwBytesInRes
            data_offset,   # dwImageOffset
        )

        entries_data.append(entry)
        image_blobs.append(blob)
        data_offset += len(blob)

    return header + b"".join(entries_data) + b"".join(image_blobs)


# ---------------------------------------------------------------------------
# ICNS file builder — constructs a spec-compliant ICNS binary
# ---------------------------------------------------------------------------

def build_icns(entries: list[tuple[bytes, bytes]]) -> bytes:
    """
    Build a complete ICNS file.

    ICNS structure:
      - Magic "icns" (4 bytes)
      - File length (4 bytes, big-endian)
      - Icon elements: each is OSType (4 bytes) + length (4 bytes) + PNG data

    The length field for each element includes the 8-byte header.
    """
    # Build all icon elements
    elements = []
    for ostype, png_data in entries:
        element_length = 8 + len(png_data)  # 4 (type) + 4 (length) + data
        element = ostype + struct.pack(">I", element_length) + png_data
        elements.append(element)

    body = b"".join(elements)
    file_length = 8 + len(body)  # 4 (magic) + 4 (file length) + body

    return b"icns" + struct.pack(">I", file_length) + body


# ---------------------------------------------------------------------------
# Main build pipeline
# ---------------------------------------------------------------------------

def build_windows_ico(svg_path: str, output_path: str) -> None:
    """Generate a standard-compliant Windows .ico from an SVG source."""
    print(f"  Building ICO: {output_path}")
    images = []
    for size in ICO_SIZES:
        png_data = svg_to_png(svg_path, size)
        pil_img = png_bytes_to_image(png_data)
        images.append((size, pil_img, png_data))
        print(f"    {size:>4}x{size:<4} {'PNG' if size >= ICO_PNG_THRESHOLD else 'BMP'}")

    ico_data = build_ico(images)
    with open(output_path, "wb") as f:
        f.write(ico_data)
    print(f"    -> {len(ico_data):,} bytes written")


def build_macos_icns(svg_path: str, output_path: str) -> None:
    """Generate a standard-compliant macOS .icns from an SVG source."""
    print(f"  Building ICNS: {output_path}")
    entries = []
    for ostype, size, desc in ICNS_ENTRIES:
        png_data = svg_to_png(svg_path, size)
        entries.append((ostype, png_data))
        print(f"    {ostype.decode():4} {size:>4}x{size:<4}  ({desc})")

    icns_data = build_icns(entries)
    with open(output_path, "wb") as f:
        f.write(icns_data)
    print(f"    -> {len(icns_data):,} bytes written")


def main():
    repo_root = Path(__file__).parent
    windows_dir = repo_root / "windows"
    macos_dir = repo_root / "macos"

    # Discover SVGs
    win_svgs = sorted(windows_dir.glob("*.svg"))
    mac_svgs = sorted(macos_dir.glob("*.svg"))

    if not win_svgs and not mac_svgs:
        print("No SVG files found.", file=sys.stderr)
        sys.exit(1)

    # Build Windows ICO files
    if win_svgs:
        print("=== Windows .ico ===")
        for svg in win_svgs:
            name = svg.stem  # e.g. "openmohaa"
            output = windows_dir / f"{name}.ico"
            build_windows_ico(str(svg), str(output))
        print()

    # Build macOS ICNS files
    if mac_svgs:
        print("=== macOS .icns ===")
        for svg in mac_svgs:
            name = svg.stem.replace("-macos", "")  # strip "-macos" suffix
            output = macos_dir / f"{name}.icns"
            build_macos_icns(str(svg), str(output))
        print()

    print("Done.")


if __name__ == "__main__":
    main()
