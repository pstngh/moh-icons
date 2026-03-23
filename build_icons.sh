#!/usr/bin/env bash
# Build standard-compliant .ico (Windows) and .icns (macOS) icon files from SVG sources.
#
# macOS .icns — Apple standard process using Xcode asset catalog compiler:
#   1. Render SVG to 1024x1024 PNG
#   2. Create temporary .xcassets with single-size AppIcon
#   3. Compile with xcrun actool (applies squircle mask automatically)
#   Reference: https://developer.apple.com/design/human-interface-guidelines/app-icons
#
# Windows .ico — Microsoft specification:
#   1. Render SVG to high-resolution PNG
#   2. Resize to all required dimensions using sips
#   3. Package with ImageMagick
#   Reference: https://learn.microsoft.com/en-us/windows/apps/design/iconography/app-icon-construction
#
# Requirements: rsvg-convert (librsvg), sips (macOS built-in), Xcode (actool), magick (ImageMagick)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Windows ICO sizes per Microsoft specification
# Base sizes: 16, 24, 32 at scale factors 100%-400%
# Deduplicated and sorted:
# ---------------------------------------------------------------------------
ICO_SIZES=(16 20 24 30 32 36 40 48 60 64 72 80 96 256)

# ---------------------------------------------------------------------------
# Build macOS .icns files using Xcode's actool (asset catalog compiler)
# ---------------------------------------------------------------------------
# actool automatically applies Apple's squircle mask and generates all
# required icon sizes from a single 1024x1024 source image.
# ---------------------------------------------------------------------------
build_macos_icns() {
  echo "=== macOS .icns ==="

  for svg in "$SCRIPT_DIR"/macos/*-macos.svg; do
    [ -f "$svg" ] || continue
    local name
    name=$(basename "$svg" -macos.svg)

    echo "  Building: ${name}.icns"

    # Step 1: Render SVG to 1024x1024 PNG
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/"${name}_actool_XXXX")
    local full_png="${tmp_dir}/icon_1024x1024.png"
    rsvg-convert -w 1024 -h 1024 "$svg" -o "$full_png"
    echo "    Rendered 1024x1024 PNG"

    # Step 2: Create temporary .xcassets with single-size AppIcon
    local xcassets="${tmp_dir}/Assets.xcassets/AppIcon.appiconset"
    mkdir -p "$xcassets"
    cp "$full_png" "$xcassets/icon_1024x1024.png"

    cat > "$xcassets/Contents.json" << 'JSONEOF'
{
  "images": [
    {
      "filename": "icon_1024x1024.png",
      "idiom": "mac",
      "platform": "macos",
      "size": "512x512@2x"
    }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
JSONEOF

    # Step 3: Compile asset catalog — actool applies the squircle mask
    local output_dir="${tmp_dir}/output"
    mkdir -p "$output_dir"
    xcrun actool \
      "${tmp_dir}/Assets.xcassets" \
      --compile "$output_dir" \
      --platform macosx \
      --target-device mac \
      --minimum-deployment-target 11.0 \
      --app-icon AppIcon \
      --include-all-app-icons \
      --output-partial-info-plist "${tmp_dir}/Info.plist"

    # Step 4: Move .icns to repo root
    mv "$output_dir/AppIcon.icns" "${SCRIPT_DIR}/${name}.icns"
    echo "    -> ${name}.icns"

    # Clean up
    rm -rf "$tmp_dir"
  done
}

# ---------------------------------------------------------------------------
# Build Windows .ico files using ImageMagick
# ---------------------------------------------------------------------------
build_windows_ico() {
  echo "=== Windows .ico ==="

  for svg in "$SCRIPT_DIR"/windows/*.svg; do
    [ -f "$svg" ] || continue
    local name
    name=$(basename "$svg" .svg)

    echo "  Building: ${name}.ico"

    # Step 1: Render SVG to high-resolution PNG
    local full_png
    full_png=$(mktemp /tmp/"${name}_full_XXXX.png")
    rsvg-convert -w 1024 -h 1024 "$svg" -o "$full_png"

    # Step 2: Generate all required sizes using sips
    local ico_inputs=()
    for size in "${ICO_SIZES[@]}"; do
      local sized_png
      sized_png=$(mktemp /tmp/"${name}_${size}_XXXX.png")
      sips -z "$size" "$size" "$full_png" --out "$sized_png" >/dev/null 2>&1
      ico_inputs+=("$sized_png")
      echo "    ${size}x${size}"
    done

    # Step 3: Create .ico using ImageMagick
    magick "${ico_inputs[@]}" "${SCRIPT_DIR}/${name}.ico"
    echo "    -> ${name}.ico"

    # Clean up
    rm -f "$full_png" "${ico_inputs[@]}"
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "Building icons..."
echo
build_macos_icns
echo
build_windows_ico
echo
echo "Done."
