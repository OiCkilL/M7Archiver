#!/usr/bin/env bash
# Build the official ip7z `7zz` CLI binary into Vendor/7zip/bin/7zz so the
# main app no longer has to fall back on a Homebrew-installed copy.
#
# Strategy:
#   1. Copy the read-only reference source from .workflow/reference/7zip to
#      Vendor/7zip/build/src/<arch>/ (one tree per arch so concurrent builds
#      don't collide).
#   2. Run `make -f makefile.gcc` for arm64 and (optionally) x86_64.
#   3. `lipo` the per-arch binaries into a universal binary at
#      Vendor/7zip/bin/7zz.
#
# Single-arch builds: pass `--arch arm64` or `--arch x86_64`.
# Default: build for host arch only — switch to `--universal` when building
# release artifacts that need to run on Intel hardware too.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SRC_REF="${REPO_ROOT}/.workflow/reference/7zip"
BUILD_ROOT="${SCRIPT_DIR}/build"
OUT_DIR="${SCRIPT_DIR}/bin"

ARCHS=("$(uname -m)")
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      shift
      ARCHS=("$1")
      ;;
    --universal)
      ARCHS=(arm64 x86_64)
      ;;
    -h|--help)
      echo "Usage: $0 [--arch arm64|x86_64] [--universal]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [[ ! -d "$SRC_REF" ]]; then
  echo "Source not found: $SRC_REF" >&2
  echo "Make sure the repo includes .workflow/reference/7zip (ip7z 26.x source)." >&2
  exit 1
fi

mkdir -p "$BUILD_ROOT" "$OUT_DIR"

build_arch() {
  local arch="$1"
  local arch_root="${BUILD_ROOT}/${arch}"
  local src_copy="${arch_root}/src"

  echo ">>> [${arch}] Preparing source tree at ${src_copy}"
  rm -rf "$arch_root"
  mkdir -p "$arch_root"
  # Copy only the directories we actually compile to keep the working tree
  # small. The makefile reaches into C/, CPP/Common, CPP/Windows, and the
  # 7zip subtree.
  rsync -a \
    --exclude='DOC/' \
    --exclude='Asm/' \
    "$SRC_REF/" "$src_copy/"

  pushd "${src_copy}/CPP/7zip/Bundles/Alone2" >/dev/null
  echo ">>> [${arch}] Compiling 7zz (jobs=${JOBS})"
  make -f makefile.gcc -j "$JOBS" \
    CC="clang -arch ${arch}" \
    CXX="clang++ -arch ${arch}" \
    AR="ar"
  popd >/dev/null

  local produced="${src_copy}/CPP/7zip/Bundles/Alone2/_o/7zz"
  if [[ ! -x "$produced" ]]; then
    echo "Build did not produce expected binary: ${produced}" >&2
    exit 1
  fi

  cp "$produced" "${arch_root}/7zz"
  echo ">>> [${arch}] Output: ${arch_root}/7zz"
}

for arch in "${ARCHS[@]}"; do
  build_arch "$arch"
done

if [[ "${#ARCHS[@]}" -gt 1 ]]; then
  echo ">>> Combining into universal binary"
  lipo -create \
    "${BUILD_ROOT}/arm64/7zz" \
    "${BUILD_ROOT}/x86_64/7zz" \
    -output "${OUT_DIR}/7zz"
else
  cp "${BUILD_ROOT}/${ARCHS[0]}/7zz" "${OUT_DIR}/7zz"
fi

strip -x "${OUT_DIR}/7zz" || true
chmod +x "${OUT_DIR}/7zz"

echo ""
echo "Built ${OUT_DIR}/7zz"
file "${OUT_DIR}/7zz"
"${OUT_DIR}/7zz" 2>&1 | head -2 || true
