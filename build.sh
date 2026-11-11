#!/bin/bash
# Builds Murmur.app into dist/. Needs Xcode Command Line Tools, git and cmake.
#   ./build.sh            build
#   ./build.sh --install  build, then copy to /Applications
set -euo pipefail
cd "$(dirname "$0")"

WHISPER=vendor/whisper.cpp
WHISPER_REF="${WHISPER_REF:-master}"

command -v cmake >/dev/null || { echo "cmake is required: brew install cmake"; exit 1; }

# 1. whisper.cpp as one static library, Metal on, shaders embedded.
if [ ! -f vendor/lib/libwhisper_all.a ]; then
    [ -d "$WHISPER" ] || git clone --depth 1 --branch "$WHISPER_REF" https://github.com/ggml-org/whisper.cpp "$WHISPER"
    cmake -S "$WHISPER" -B "$WHISPER/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF -DGGML_CCACHE=OFF \
        -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 >/dev/null
    cmake --build "$WHISPER/build" -j "$(sysctl -n hw.ncpu)" >/dev/null
    mkdir -p vendor/lib
    libtool -static -o vendor/lib/libwhisper_all.a $(find "$WHISPER/build" -name '*.a' ! -name 'libparakeet.a') 2>/dev/null
fi
mkdir -p Sources/CWhisper/include
cp "$WHISPER/include/whisper.h" "$WHISPER"/ggml/include/{ggml.h,ggml-cpu.h,ggml-backend.h,ggml-alloc.h} Sources/CWhisper/include/

# 2. The app and its checks.
swift build -c release
.build/release/MurmurCheck

# 3. The bundle.
APP=dist/Murmur.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Murmur "$APP/Contents/MacOS/Murmur"
strip -x "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The icon is drawn by the app itself, then packed into an .icns.
TMP=$(mktemp -d)
.build/release/Murmur --render-icon "$TMP/icon.png"
ICONSET="$TMP/AppIcon.iconset"; mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$TMP/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$TMP/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"

# Sign with a stable identity when there is one, so macOS keeps the app's permissions across
# rebuilds. macOS 27 ignores Accessibility grants for ad-hoc signed apps entirely.
# Run scripts/make-signing-cert.sh once to create a local identity, or set SIGN_ID yourself.
if [ -z "${SIGN_ID:-}" ] && security find-certificate -c "Murmur Local Signing" >/dev/null 2>&1; then
    SIGN_ID="Murmur Local Signing"
fi
if [ -z "${SIGN_ID:-}" ]; then
    echo "warning: ad-hoc signing. Run scripts/make-signing-cert.sh first, or the Fn key and pasting may not work."
fi
codesign --force --options runtime --entitlements Resources/Murmur.entitlements --sign "${SIGN_ID:--}" "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
if [ "${1:-}" = "--install" ]; then
    rm -rf /Applications/Murmur.app
    cp -R "$APP" /Applications/Murmur.app
    echo "Installed to /Applications/Murmur.app"
fi
