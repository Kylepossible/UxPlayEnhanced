#!/bin/bash
# Build UxPlay with embedded mDNS (no Bonjour required)
# Requires MSYS2 with mingw-w64-x86_64 packages installed.
#
# Prerequisites (run in MSYS2 MinGW64 shell):
#   pacman -S --needed mingw-w64-x86_64-toolchain mingw-w64-x86_64-cmake \
#     mingw-w64-x86_64-gstreamer mingw-w64-x86_64-gst-plugins-base \
#     mingw-w64-x86_64-gst-plugins-good mingw-w64-x86_64-gst-plugins-bad \
#     mingw-w64-x86_64-gst-libav mingw-w64-x86_64-openssl \
#     mingw-w64-x86_64-libplist mingw-w64-x86_64-pkg-config

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
DIST_DIR="$SCRIPT_DIR/dist/UxPlay"

echo "=== Copying embedded mDNS source ==="
cp "$SCRIPT_DIR/src/dnssd_embedded.c" "$SCRIPT_DIR/lib/uxplay/lib/dnssd_embedded.c"

echo "=== Patching CMakeLists.txt for embedded mDNS ==="
python "$SCRIPT_DIR/patch_cmake.py"

echo "=== Configuring build ==="
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cmake "$SCRIPT_DIR/lib/uxplay" \
    -G "MinGW Makefiles" \
    -DUSE_EMBEDDED_MDNS=ON \
    -DNO_MARCH_NATIVE=ON \
    -DCMAKE_BUILD_TYPE=Release

echo "=== Building ==="
mingw32-make -j$(nproc)

echo "=== Packaging ==="
mkdir -p "$DIST_DIR/lib/gstreamer-1.0"

# Copy executable
cp "$BUILD_DIR/uxplay.exe" "$DIST_DIR/"

# Copy all required DLLs (resolve transitive deps)
copy_deps() {
    local changed=1
    while [ $changed -ne 0 ]; do
        changed=0
        for f in "$DIST_DIR"/*.dll "$DIST_DIR"/lib/gstreamer-1.0/*.dll "$DIST_DIR"/uxplay.exe; do
            [ -f "$f" ] || continue
            for dll in $(ldd "$f" 2>/dev/null | grep mingw64 | awk '{print $3}'); do
                base=$(basename "$dll")
                if [ ! -f "$DIST_DIR/$base" ]; then
                    cp "$dll" "$DIST_DIR/"
                    changed=1
                fi
            done
        done
    done
}

# Copy GStreamer runtime libs
for lib in libgstvideo-1.0-0 libgstsdp-1.0-0 libgstpbutils-1.0-0 \
           libgstaudio-1.0-0 libgsttag-1.0-0 libgstrtp-1.0-0 \
           libgstgl-1.0-0 libgstcodecparsers-1.0-0 liborc-0.4-0; do
    cp /mingw64/bin/${lib}.dll "$DIST_DIR/" 2>/dev/null || true
done

# FFmpeg's avcodec can import xvidcore.dll. On the build PC, ldd may resolve
# it from Windows/System32, so copy the MinGW runtime explicitly for portable
# installs on machines without that system DLL.
cp /mingw64/bin/xvidcore.dll "$DIST_DIR/" 2>/dev/null || \
    echo "WARNING: /mingw64/bin/xvidcore.dll was not found; avcodec may not load on another PC"

# Copy GStreamer plugins
for plugin in libgstcoreelements libgstplayback libgstvideoconvertscale \
              libgstautodetect libgstaudioconvert libgstaudioresample \
              libgstvolume libgsttypefindfunctions libgstapp \
              libgstvideoparsersbad libgstisomp4 libgstrtp libgstrtpmanager \
              libgstudp libgstopengl libgstrtsp libgstlibav \
              libgstlevel libgstaudioparsers libgstvideofilter \
              libgstd3d11 libgstwasapi2 libgstd3d12 \
              libgstdirectsound libgstwasapi \
              libgstalaw libgstmulaw libgstsubparse libgstencoding; do
    cp /mingw64/lib/gstreamer-1.0/${plugin}.dll "$DIST_DIR/lib/gstreamer-1.0/" 2>/dev/null || true
done

# Resolve all transitive DLL dependencies
copy_deps

# Copy launcher files
cp "$SCRIPT_DIR/launcher/"* "$DIST_DIR/"

echo ""
echo "=== Build complete ==="
echo "Output: $DIST_DIR"
echo "Files: $(find "$DIST_DIR" -name '*.dll' | wc -l) DLLs, $(find "$DIST_DIR" -name '*.exe' | wc -l) EXE"
echo ""
echo "To use:"
echo "  1. Run setup-firewall.ps1 as Administrator (first time only)"
echo "  2. Double-click UxPlay.bat or run uxplay_tray.pyw"
