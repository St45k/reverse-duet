#!/usr/bin/env bash
# Builds "build/Reverse Duet.app" from the Swift package.
#
#   scripts/build-app.sh              # release build for this Mac's architecture
#   UNIVERSAL=1 scripts/build-app.sh  # arm64 + x86_64
#   SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh
#
# Ad-hoc signing (the default) works, but macOS asks for Screen Recording /
# Accessibility again after every rebuild. Sign with a stable identity to
# keep those permissions between builds.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/Reverse Duet.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ReverseDuet" "$APP/Contents/MacOS/ReverseDuet"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Sources/ReverseDuet/Web "$APP/Contents/Resources/Web"

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
echo "Run it with: open \"$APP\""
