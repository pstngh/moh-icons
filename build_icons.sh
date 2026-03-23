#!/usr/bin/env bash
# Build standard-compliant .ico (Windows) and .icns (macOS) icon files from SVG sources.
#
# macOS .icns — Apple standard process:
#   1. Render SVG to 1024x1024 PNG with squircle clip-path applied
#   2. Resize to all required dimensions using sips
#   3. Place in .iconset directory with Apple's naming convention
#   4. Package with iconutil -c icns
#   Reference: https://developer.apple.com/design/human-interface-guidelines/app-icons
#
# Windows .ico — Microsoft specification:
#   1. Render SVG to high-resolution PNG
#   2. Resize to all required dimensions using sips
#   3. Package with ImageMagick
#   Reference: https://learn.microsoft.com/en-us/windows/apps/design/iconography/app-icon-construction
#
# Requirements: rsvg-convert (librsvg), sips (macOS built-in), iconutil (macOS built-in), magick (ImageMagick)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# macOS iconset sizes per Apple Human Interface Guidelines
# https://developer.apple.com/design/human-interface-guidelines/app-icons#macOS-app-icon-sizes
#
# Each icon in the .iconset must be named icon_{base}[@2x].png
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
# The macOS SVGs contain the icon artwork plus an App_Icon_Shape overlay
# group that visually masks corners. For .icns generation, we replace this
# overlay with a proper SVG clip-path so the rendered PNG has transparent
# corners matching the exact Apple continuous corner curve.
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
# Build macOS .icns files using Apple's standard iconutil workflow
# ---------------------------------------------------------------------------
build_macos_icns() {
  echo "=== macOS .icns ==="

  for svg in "$SCRIPT_DIR"/macos/*-macos.svg; do
    [ -f "$svg" ] || continue
    local name
    name=$(basename "$svg" -macos.svg)
    local iconset="${SCRIPT_DIR}/${name}.iconset"

    echo "  Building: ${name}.icns"

    # Step 1: Preprocess SVG — apply squircle clip-path, strip overlay
    local tmp_svg
    tmp_svg=$(mktemp /tmp/"${name}_clipped_XXXX.svg")
    preprocess_macos_svg "$svg" "$tmp_svg"

    # Step 2: Render SVG to full-size 1024x1024 PNG
    local full_png
    full_png=$(mktemp /tmp/"${name}_1024_XXXX.png")
    rsvg-convert -w 1024 -h 1024 "$tmp_svg" -o "$full_png"

    # Step 3: Create .iconset directory with all required sizes using sips
    mkdir -p "$iconset"
    for entry in "${ICONSET_ENTRIES[@]}"; do
      IFS=: read -r base retina pixels <<< "$entry"
      local filename
      if [ "$retina" = "1x" ]; then
        filename="icon_${base}.png"
      else
        filename="icon_${base}@${retina}.png"
      fi

      sips -z "$pixels" "$pixels" "$full_png" --out "$iconset/$filename" >/dev/null 2>&1
      echo "    ${filename} (${pixels}x${pixels})"
    done

    # Step 4: Create .icns using Apple's iconutil
    iconutil -c icns "$iconset" -o "${SCRIPT_DIR}/${name}.icns"
    echo "    -> ${name}.icns"

    # Clean up
    rm -rf "$iconset" "$tmp_svg" "$full_png"
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
