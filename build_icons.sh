#!/usr/bin/env bash
# Build standard-compliant .ico (Windows) and .icns (macOS) icon files.
#
# macOS .icns — Two input paths supported:
#   A) From SVG (macos/*-macos.svg):
#      1. Preprocess SVG: apply Apple squircle as clip-path (baked into pixels)
#      2. Render clipped SVG to 1024x1024 PNG
#      3. Resize, build .xcassets, compile with actool
#   B) From PNG (macos/png/*.png — exported from Icon Composer at 1024x1024):
#      1. Use PNG directly (squircle already baked in by Icon Composer)
#      2. Resize, build .xcassets, compile with actool
#   Note: --minimum-deployment-target < 10.13 forces standalone .icns output
#         (>= 10.13 embeds into Assets.car instead).
#   Reference: https://developer.apple.com/design/human-interface-guidelines/app-icons
#
# Windows .ico — Microsoft specification:
#   1. Render SVG to high-resolution PNG
#   2. Resize to all required dimensions using sips
#   3. Package with ImageMagick
#   Reference: https://learn.microsoft.com/en-us/windows/apps/design/iconography/app-icon-construction
#
# Requirements: sips (macOS built-in), Xcode (actool)
# Optional: rsvg-convert (librsvg) for SVG input, magick (ImageMagick) for .ico, python3 for SVG preprocessing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# macOS iconset sizes per Apple Human Interface Guidelines
# https://developer.apple.com/design/human-interface-guidelines/app-icons#macOS-app-icon-sizes
# Format: "WxH:scale:pixels" where pixels is the actual rendered size
# ---------------------------------------------------------------------------
ICONSET_ENTRIES=(
  "16x16:1x:16"
  "16x16:2x:32"
  "32x32:1x:32"
  "32x32:2x:64"
  "128x128:1x:128"
  "128x128:2x:256"
  "256x256:1x:256"
  "256x256:2x:512"
  "512x512:1x:512"
  "512x512:2x:1024"
)

# ---------------------------------------------------------------------------
# Windows ICO sizes per Microsoft specification
# Base sizes: 16, 24, 32 at scale factors 100%-400%
# Deduplicated and sorted:
# ---------------------------------------------------------------------------
ICO_SIZES=(16 20 24 30 32 36 40 48 60 64 72 80 96 256)

# ---------------------------------------------------------------------------
# Preprocess macOS SVG: apply Apple squircle as clip-path
# ---------------------------------------------------------------------------
# The .icns format stores raw pixels with no masking feature. For icons to
# display with the correct squircle shape on pre-Tahoe macOS (Big Sur through
# Sequoia), the mask must be baked into the PNG. This function applies Apple's
# squircle curve as an SVG clip-path before rasterization.
# ---------------------------------------------------------------------------
preprocess_macos_svg() {
  local input="$1"
  local output="$2"

  python3 - "$input" "$output" << 'PYEOF'
import re, sys

input_path, output_path = sys.argv[1], sys.argv[2]
svg = open(input_path).read()

# Apple squircle path (1024x1024 coordinate space)
# Extracted from the App_Icon_Shape group in the source SVGs
SQUIRCLE = (
    "M1024,651c0,14.24,0,28.48-.08,42.73-.07,12-.21,23.99-.53,35.98"
    "-.71,26.13-2.25,52.49-6.89,78.34-4.71,26.22-12.4,50.62-24.53,74.44"
    "-11.92,23.41-27.49,44.84-46.07,63.41s-40,34.15-63.41,46.07"
    "c-23.82,12.12-48.22,19.82-74.44,24.53-25.84,4.65-52.2,6.18-78.34,6.89"
    "-11.99.33-23.99.46-35.98.53-14.24.09-28.48.08-42.73.08h-278"
    "c-14.24,0-28.48,0-42.73-.08-12-.07-23.99-.21-35.98-.53"
    "-26.13-.71-52.49-2.25-78.34-6.89-26.22-4.71-50.62-12.4-74.44-24.53"
    "-23.41-11.92-44.84-27.49-63.41-46.07s-34.15-40-46.07-63.41"
    "c-12.12-23.82-19.82-48.22-24.53-74.44-4.65-25.84-6.18-52.2-6.89-78.34"
    "-.33-11.99-.46-23.99-.53-35.98C0,679.48,0,665.24,0,651v-278"
    "C0,358.76,0,344.52.08,330.27c.07-12,.21-23.99.53-35.98"
    ".71-26.13,2.25-52.49,6.89-78.34,4.71-26.22,12.4-50.62,24.53-74.44"
    ",11.92-23.41,27.49-44.84,46.07-63.41s40-34.15,63.41-46.07"
    "c23.82-12.12,48.22-19.82,74.44-24.53,25.84-4.65,52.2-6.18,78.34-6.89"
    ",11.99-.33,23.99-.46,35.98-.53C344.52,0,358.76,0,373,0h278"
    "c14.24,0,28.48,0,42.73.08,12,.07,23.99.21,35.98.53"
    ",26.13.71,52.49,2.25,78.34,6.89,26.22,4.71,50.62,12.4,74.44,24.53"
    ",23.41,11.92,44.84,27.49,63.41,46.07s34.15,40,46.07,63.41"
    "c12.12,23.82,19.82,48.22,24.53,74.44,4.65,25.84,6.18,52.2,6.89,78.34"
    ",.33,11.99,.46,23.99,.53,35.98,.09,14.24,.08,28.48,.08,42.73v278Z"
)

# Remove App_Icon_Shape group (gray squircle overlay)
svg = re.sub(r'\s*<g\s+id="App_Icon_Shape">.*?</g>', '', svg, flags=re.DOTALL)

# Remove Grid group (hidden design grid)
svg = re.sub(r'\s*<g\s+id="Grid"[^>]*>.*?</g>\s*</g>', '', svg, flags=re.DOTALL)

# Insert squircle clipPath definition into <defs>
clip_def = f'<clipPath id="squircle"><path d="{SQUIRCLE}"/></clipPath>'
svg = svg.replace('</defs>', f'    {clip_def}\n  </defs>')

# Wrap all visible content groups in a clipped group
svg = re.sub(r'(</defs>\s*)', r'\1  <g clip-path="url(#squircle)">\n', svg)
svg = svg.replace('</svg>', '  </g>\n</svg>')

open(output_path, 'w').write(svg)
PYEOF
}

# ---------------------------------------------------------------------------
# Convert a 1024x1024 PNG to .icns using actool
# Usage: png_to_icns <input.png> <output_name>
# ---------------------------------------------------------------------------
png_to_icns() {
  local full_png="$1"
  local name="$2"

  local tmp_dir
  tmp_dir=$(mktemp -d /tmp/"${name}_actool_XXXX")

  # Create .xcassets with all required icon sizes
  local xcassets="${tmp_dir}/Assets.xcassets/AppIcon.appiconset"
  mkdir -p "$xcassets"

  local json_images=""
  for entry in "${ICONSET_ENTRIES[@]}"; do
    IFS=: read -r base scale pixels <<< "$entry"
    local filename
    if [ "$scale" = "1x" ]; then
      filename="icon_${base}.png"
    else
      filename="icon_${base}@${scale}.png"
    fi

    sips -z "$pixels" "$pixels" "$full_png" --out "$xcassets/$filename" >/dev/null 2>&1
    echo "    ${filename} (${pixels}x${pixels})"

    [ -n "$json_images" ] && json_images="${json_images},"
    json_images="${json_images}
    {\"filename\":\"${filename}\",\"idiom\":\"mac\",\"scale\":\"${scale}\",\"size\":\"${base}\"}"
  done

  cat > "$xcassets/Contents.json" << JSONEOF
{
  "images": [${json_images}
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
JSONEOF

  # Compile asset catalog with actool
  local output_dir="${tmp_dir}/output"
  mkdir -p "$output_dir"
  xcrun actool \
    "${tmp_dir}/Assets.xcassets" \
    --compile "$output_dir" \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 10.9 \
    --app-icon AppIcon \
    --include-all-app-icons \
    --output-partial-info-plist "${tmp_dir}/Info.plist"

  mv "$output_dir/AppIcon.icns" "${SCRIPT_DIR}/${name}.icns"
  echo "    -> ${name}.icns"

  rm -rf "$tmp_dir"
}

# ---------------------------------------------------------------------------
# Build macOS .icns from PNG files exported from Icon Composer
# Expects 1024x1024 PNGs in macos/png/ with squircle already baked in
# ---------------------------------------------------------------------------
build_macos_icns_from_png() {
  local found=false
  for png in "$SCRIPT_DIR"/macos/png/*.png; do
    [ -f "$png" ] || continue
    found=true
    local name
    name=$(basename "$png" .png)
    echo "  Building from PNG: ${name}.icns"
    png_to_icns "$png" "$name"
  done
  $found
}

# ---------------------------------------------------------------------------
# Build macOS .icns from SVG sources (fallback when no PNGs available)
# Preprocesses SVGs with squircle clip-path before rasterization
# ---------------------------------------------------------------------------
build_macos_icns_from_svg() {
  for svg in "$SCRIPT_DIR"/macos/*-macos.svg; do
    [ -f "$svg" ] || continue
    local name
    name=$(basename "$svg" -macos.svg)

    echo "  Building from SVG: ${name}.icns"

    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/"${name}_svg_XXXX")

    # Preprocess SVG — apply squircle clip-path, strip overlay
    local tmp_svg="${tmp_dir}/${name}_clipped.svg"
    preprocess_macos_svg "$svg" "$tmp_svg"

    # Render clipped SVG to 1024x1024 PNG
    local full_png="${tmp_dir}/full_1024.png"
    rsvg-convert -w 1024 -h 1024 "$tmp_svg" -o "$full_png"

    png_to_icns "$full_png" "$name"

    rm -rf "$tmp_dir"
  done
}

# ---------------------------------------------------------------------------
# Build macOS .icns — prefers PNG input, falls back to SVG
# ---------------------------------------------------------------------------
build_macos_icns() {
  echo "=== macOS .icns ==="

  if [ -d "$SCRIPT_DIR/macos/png" ] && ls "$SCRIPT_DIR"/macos/png/*.png >/dev/null 2>&1; then
    echo "  Using PNG sources from macos/png/"
    build_macos_icns_from_png
  else
    echo "  No PNGs found, using SVG sources from macos/"
    build_macos_icns_from_svg
  fi
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
