#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-release}"
ZIP_RELEASE=false
for arg in "${@:2}"; do
  case "$arg" in
    --zip) ZIP_RELEASE=true ;;
    *)
      echo "usage: $0 [debug|release] [--zip]" >&2
      exit 1
      ;;
  esac
done

case "$MODE" in
  debug)
    SWIFT_CONFIG="debug"
    GO_LDFLAGS=""
    APP_NAME="Lunar Debug"
    BUNDLE_ID="com.lunar.macos.debug"
    ;;
  release)
    SWIFT_CONFIG="release"
    GO_LDFLAGS="-s -w"
    APP_NAME="Lunar"
    BUNDLE_ID="com.lunar.macos"
    ;;
  *)
    echo "error: unknown mode '$MODE' (expected debug or release)" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_DIR="$ROOT_DIR/core"
SWIFT_DIR="$ROOT_DIR/LunarApp"
BUILD_DIR="$ROOT_DIR/build/$MODE"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_VERSION="${APP_VERSION:-1.0.0}"
APP_BUILD="${APP_BUILD:-1}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

mkdir -p "$BUILD_DIR"

echo "==> Generating AppIcon.icns ($MODE)"
ICNS_PATH="$BUILD_DIR/AppIcon.icns"
"$SCRIPT_DIR/generate_icns.sh" "$SCRIPT_DIR/AppIcon.svg" "$ICNS_PATH"

echo "==> Building lunar-core (Go, $MODE)"
CORE_BIN="$BUILD_DIR/lunar-core"
(
  cd "$CORE_DIR"
  if [[ -n "$GO_LDFLAGS" ]]; then
    go build -ldflags="$GO_LDFLAGS" -o "$CORE_BIN" ./cmd/lunar-core
  else
    go build -o "$CORE_BIN" ./cmd/lunar-core
  fi
)

echo "==> Building LunarApp (Swift, $SWIFT_CONFIG)"
(
  cd "$SWIFT_DIR"
  swift build -c "$SWIFT_CONFIG"
)
SWIFT_BIN_DIR="$(cd "$SWIFT_DIR" && swift build -c "$SWIFT_CONFIG" --show-bin-path)"
SWIFT_EXEC="$SWIFT_BIN_DIR/LunarApp"
SWIFT_BUNDLE="$SWIFT_BIN_DIR/LunarApp_LunarApp.bundle"

if [[ ! -x "$SWIFT_EXEC" ]]; then
  echo "error: Swift executable not found at $SWIFT_EXEC" >&2
  exit 1
fi
if [[ ! -d "$SWIFT_BUNDLE" ]]; then
  echo "error: Swift resource bundle not found at $SWIFT_BUNDLE" >&2
  exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$SWIFT_EXEC" "$MACOS_DIR/Lunar"
chmod +x "$MACOS_DIR/Lunar"

cp "$CORE_BIN" "$MACOS_DIR/lunar-core"
chmod +x "$MACOS_DIR/lunar-core"

cp "$ICNS_PATH" "$RESOURCES_DIR/AppIcon.icns"
cp -R "$SWIFT_BUNDLE" "$RESOURCES_DIR/LunarApp_LunarApp.bundle"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>Lunar</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "==> Signing $APP_DIR ($CODESIGN_IDENTITY)"
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "Built and signed $APP_DIR"

if [[ "$ZIP_RELEASE" == true ]]; then
  ZIP_PATH="$BUILD_DIR/Lunar-${APP_VERSION}-macos.zip"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
  echo "Packaged $ZIP_PATH"
fi
