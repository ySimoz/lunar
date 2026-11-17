#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SVG_PATH="${1:-$SCRIPT_DIR/AppIcon.svg}"
OUT_ICNS="${2:-$SCRIPT_DIR/AppIcon.icns}"

if [[ ! -f "$SVG_PATH" ]]; then
  echo "error: SVG not found at $SVG_PATH" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

BASE_PNG="$WORK_DIR/icon_1024.png"
ICONSET_DIR="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR" "$(dirname "$OUT_ICNS")"

swift - "$SVG_PATH" "$BASE_PNG" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: swift - <svg> <out.png>\n", stderr)
    exit(1)
}
let svgURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let image = NSImage(contentsOf: svgURL) else {
    fputs("failed to load SVG: \(svgURL.path)\n", stderr)
    exit(1)
}

let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("failed to allocate bitmap\n", stderr)
    exit(1)
}
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.clear.set()
NSRect(x: 0, y: 0, width: size, height: size).fill()
image.draw(
    in: NSRect(x: 0, y: 0, width: size, height: size),
    from: .zero,
    operation: .sourceOver,
    fraction: 1.0
)
NSGraphicsContext.restoreGraphicsState()

guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to encode PNG\n", stderr)
    exit(1)
}
try pngData.write(to: outURL)
SWIFT

resize_icon() {
  local px="$1"
  local name="$2"
  sips -z "$px" "$px" "$BASE_PNG" --out "$ICONSET_DIR/$name" >/dev/null
}

resize_icon 16   "icon_16x16.png"
resize_icon 32   "icon_16x16@2x.png"
resize_icon 32   "icon_32x32.png"
resize_icon 64   "icon_32x32@2x.png"
resize_icon 128  "icon_128x128.png"
resize_icon 256  "icon_128x128@2x.png"
resize_icon 256  "icon_256x256.png"
resize_icon 512  "icon_256x256@2x.png"
resize_icon 512  "icon_512x512.png"
cp "$BASE_PNG" "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$OUT_ICNS"
echo "Generated $OUT_ICNS"
