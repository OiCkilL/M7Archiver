#!/bin/bash
set -euo pipefail

# sync-open-source-tree.sh
# Syncs the public M7Archiver repo from the private maczip working copy.
# Usage: ./scripts/sync-open-source-tree.sh [TARGET_DIR]
# Default target: ../M7Archiver

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${1:-$SRC_DIR/../M7Archiver}"

echo "==> Source: $SRC_DIR"
echo "==> Target: $TARGET"

# --- Excluded paths (private/dev-only, build artifacts) ---
EXCLUDES=(
  ".workflow/"
  ".claude/"
  ".omx/"
  ".omc/"
  ".agents/"
  ".antigravitycli/"
  ".xcodebuildmcp/"
  ".rtk/"
  ".figma-assets/"
  ".logs/"
  ".build/"
  ".swiftpm/"
  "Package.resolved"
  ".DS_Store"
  "CLAUDE.md"
  "GEMINI.md"
  "AGENTS.md"
  "secret.txt"
  "skills-lock.json"
  "run.log"
  "*.app"
  "*.appex"
  "*.dSYM/"
  "DerivedData/"
  "Vendor/7zip/build/"
  "Vendor/7zip/bin/"
  "Vendor/libarchive/build/"
  "Vendor/libarchive/lib/"
  "Vendor/libarchive/include/"
)

# Build rsync exclude args
RSYNC_EXCLUDES=()
for excl in "${EXCLUDES[@]}"; do
  RSYNC_EXCLUDES+=(--exclude="$excl")
done

mkdir -p "$TARGET"

echo "==> Syncing..."
rsync -a --delete \
  "${RSYNC_EXCLUDES[@]}" \
  --exclude=".git/" \
  "$SRC_DIR/" "$TARGET/"

echo "==> Validating..."
VIOLATIONS=0
for pattern in '\.workflow/' '\.claude/' '\.omx/' '\.omc/' 'secret\.txt' 'skills-lock\.json' '\.maestro/'; do
  while IFS= read -r -d '' file; do
    echo "  WARN: $file references private path '$pattern'"
    VIOLATIONS=$((VIOLATIONS + 1))
  done < <(find "$TARGET" -type f \( -name "*.swift" -o -name "*.sh" -o -name "*.md" -o -name "*.json" -o -name "*.plist" \) -print0 | xargs -0 grep -lE "$pattern" 2>/dev/null || true)
done

if [ "$VIOLATIONS" -gt 0 ]; then
  echo "WARNING: $VIOLATIONS private reference(s) found. Review before publishing."
else
  echo "  Clean."
fi

echo ""
echo "==> Package resolution check..."
(cd "$TARGET" && swift package resolve 2>&1) && echo "  OK" || echo "  FAILED"

echo ""
echo "==> Sync complete: $TARGET"
echo "    Files: $(find "$TARGET" -type f -not -path '*/.git/*' | wc -l | tr -d ' ')"
