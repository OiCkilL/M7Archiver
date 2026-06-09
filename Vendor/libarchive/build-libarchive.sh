#!/usr/bin/env bash
# Build libarchive as a universal (arm64 + x86_64) static archive into
# Vendor/libarchive/lib/libarchive.a. Headers go to Vendor/libarchive/include.
#
# Strategy:
#   1. Copy the read-only reference source from .workflow/reference/libarchive
#      into Vendor/libarchive/build/src.
#   2. Configure with cmake using CMAKE_OSX_ARCHITECTURES="arm64;x86_64".
#      Disable features that would require non-universal Homebrew dylibs
#      (lzma/zstd/lz4/xml2/openssl). Keep zlib + bzip2 (macOS ships them
#      universal at /usr/lib).
#   3. Build only the static library — no bsdtar/bsdcpio/bsdcat tools.
#   4. Copy `libarchive.a` and the public headers into Vendor/libarchive/.
#
# Format trade-off: this build supports zip, tar, gzip, bzip2, ar, cpio,
# iso, xar, mtree, 7z (libarchive bakes in its own LZMA SDK for 7z reads).
# It does NOT cover xz, zstd, lz4, and tar.* compounds backed by those —
# those route through SevenZipEngine (the official ip7z binary handles
# them) at the engine-selector layer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SRC_REF="${REPO_ROOT}/.workflow/reference/libarchive"
BUILD_ROOT="${SCRIPT_DIR}/build"
LIB_DIR="${SCRIPT_DIR}/lib"
INCLUDE_DIR="${SCRIPT_DIR}/include"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

if [[ ! -d "$SRC_REF" ]]; then
  echo "Source not found: $SRC_REF" >&2
  exit 1
fi

mkdir -p "$BUILD_ROOT" "$LIB_DIR" "$INCLUDE_DIR"

SRC_COPY="${BUILD_ROOT}/src"
echo ">>> Preparing source tree"
rm -rf "$SRC_COPY"
mkdir -p "$BUILD_ROOT"
# Keep libarchive's own `build/` directory — cmake needs
#   - build/version
#   - build/cmake/*.cmake
# Excluding it breaks configuration.
rsync -a "$SRC_REF/" "$SRC_COPY/"

CMAKE_BUILD="${BUILD_ROOT}/cmake-build"
rm -rf "$CMAKE_BUILD"
mkdir -p "$CMAKE_BUILD"

echo ">>> Configuring cmake (universal: arm64;x86_64)"
cmake -S "$SRC_COPY" -B "$CMAKE_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_TEST=OFF \
  -DENABLE_TAR=OFF \
  -DENABLE_CPIO=OFF \
  -DENABLE_CAT=OFF \
  -DENABLE_UNZIP=OFF \
  -DENABLE_INSTALL=OFF \
  -DENABLE_ZLIB=ON \
  -DENABLE_BZip2=ON \
  -DENABLE_LZMA=OFF \
  -DENABLE_LZ4=OFF \
  -DENABLE_LZO=OFF \
  -DENABLE_ZSTD=OFF \
  -DENABLE_LIBB2=OFF \
  -DENABLE_LIBXML2=OFF \
  -DENABLE_EXPAT=OFF \
  -DENABLE_OPENSSL=OFF \
  -DENABLE_CNG=OFF \
  -DENABLE_ICONV=ON \
  -DENABLE_ACL=ON \
  -DENABLE_XATTR=ON

echo ">>> Building (jobs=${JOBS})"
cmake --build "$CMAKE_BUILD" --parallel "$JOBS" --target archive_static

ARTIFACT="${CMAKE_BUILD}/libarchive/libarchive.a"
if [[ ! -f "$ARTIFACT" ]]; then
  echo "Did not find expected build artifact: ${ARTIFACT}" >&2
  exit 1
fi

cp "$ARTIFACT" "${LIB_DIR}/libarchive.a"

# Copy public headers used by CLibArchiveBridge.c. The cmake build also
# generates `archive_platform.h` and friends inside the build dir, but those
# are private; only `archive.h` and `archive_entry.h` are public.
cp "${SRC_COPY}/libarchive/archive.h" "${INCLUDE_DIR}/archive.h"
cp "${SRC_COPY}/libarchive/archive_entry.h" "${INCLUDE_DIR}/archive_entry.h"

echo ""
echo "Built ${LIB_DIR}/libarchive.a"
file "${LIB_DIR}/libarchive.a"
lipo -archs "${LIB_DIR}/libarchive.a" 2>/dev/null || true
ls -la "${INCLUDE_DIR}/"
