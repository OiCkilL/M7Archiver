#!/bin/bash
set -euo pipefail

APP_DIR="${1:-.build/M7Archiver.app}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

require_file() {
    local path="$1"
    [ -f "$path" ] || fail "Missing file: $path"
}

require_dir() {
    local path="$1"
    [ -d "$path" ] || fail "Missing directory: $path"
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print $2" "$1"
}

require_plist_value() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local actual
    actual=$(plist_value "$plist" "$key")
    [ "$actual" = "$expected" ] || fail "$plist $key expected '$expected', got '$actual'"
}

require_extension_main() {
    local executable="$1"
    nm -u "$executable" | rg -q '_NSExtensionMain' \
        || fail "$executable does not reference NSExtensionMain"
}

require_no_embedded_entitlements() {
    local bundle="$1"
    local found
    found=$(find "$bundle" -name '*.entitlements' -print)
    [ -z "$found" ] || fail "Entitlement source files should not be embedded: $found"
}

require_archive_core_bundle() {
    local bundle_root="$1"
    local resource="$bundle_root/Contents/Resources/M7Archiver_ArchiveCore.bundle/ArchiveFormatCatalog.json"
    require_file "$resource"
}

require_dir "$APP_DIR"
require_file "$APP_DIR/Contents/Info.plist"
require_file "$APP_DIR/Contents/MacOS/M7ArchiverApp"
require_plist_value "$APP_DIR/Contents/Info.plist" ':CFBundlePackageType' 'APPL'
require_archive_core_bundle "$APP_DIR"
require_no_embedded_entitlements "$APP_DIR"

for target in FinderExtension QuickLookPreviewExtension QuickLookThumbnailExtension; do
    appex="$APP_DIR/Contents/PlugIns/$target.appex"
    require_dir "$appex"
    require_file "$appex/Contents/Info.plist"
    require_file "$appex/Contents/MacOS/$target"
    require_plist_value "$appex/Contents/Info.plist" ':CFBundlePackageType' 'XPC!'
    require_extension_main "$appex/Contents/MacOS/$target"
done

require_archive_core_bundle "$APP_DIR/Contents/PlugIns/QuickLookPreviewExtension.appex"
require_archive_core_bundle "$APP_DIR/Contents/PlugIns/QuickLookThumbnailExtension.appex"

echo "App bundle validation passed: $APP_DIR"
