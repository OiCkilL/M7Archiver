#!/bin/bash
set -e
cd "$(dirname "$0")/.."

BUILD_DIR=$(swift build --show-bin-path -c debug)
APP_DIR=".build/M7Archiver.app"
VERSION="1.0.0"
BUILD_NUMBER="1"

echo "==> Building M7ArchiverApp..."
swift build -c debug --product M7ArchiverApp

echo "==> Building extension targets..."
swift build -c debug --product FinderExtension 2>/dev/null || echo "    (FinderExtension skipped)"
swift build -c debug --product QuickLookPreviewExtension 2>/dev/null || echo "    (QuickLookPreviewExtension skipped)"
swift build -c debug --product QuickLookThumbnailExtension 2>/dev/null || echo "    (QuickLookThumbnailExtension skipped)"

echo "==> Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/PlugIns"

cp "$BUILD_DIR/M7ArchiverApp" "$APP_DIR/Contents/MacOS/"

copy_archive_core_resources() {
    local dest_root="$1"
    local resource_bundle="$BUILD_DIR/M7Archiver_ArchiveCore.bundle"
    if [ ! -d "$resource_bundle" ]; then
        echo "    (Warning: ArchiveCore resource bundle not found at $resource_bundle)"
        return
    fi
    mkdir -p "$dest_root/Contents/Resources"
    cp -R "$resource_bundle" "$dest_root/Contents/Resources/"
}

copy_seven_zip_cli() {
    local dest_root="$1"
    local cli_src="Vendor/7zip/bin/7zz"
    local cli_dst="$dest_root/Contents/Resources/7zz"
    if [ ! -x "$cli_src" ]; then
        echo "    (Warning: 7zz binary not found at $cli_src)"
        return
    fi
    mkdir -p "$dest_root/Contents/Resources"
    cp "$cli_src" "$cli_dst"
    chmod 755 "$cli_dst"
}

copy_archive_core_resources "$APP_DIR"
copy_seven_zip_cli "$APP_DIR"

# Embed extension .appex bundles
embed_extension() {
    local target="$1"
    local executable="$2"
    local plist_src="$3"
    local entitlements_src="$4"
    local appex_dir="$APP_DIR/Contents/PlugIns/${target}.appex"

    if [ ! -f "$BUILD_DIR/$executable" ]; then
        echo "    (Skipping $target — binary not found)"
        return
    fi

    mkdir -p "$appex_dir/Contents/MacOS"
    mkdir -p "$appex_dir/Contents/Resources"
    cp "$BUILD_DIR/$executable" "$appex_dir/Contents/MacOS/"

    if [ -f "$plist_src" ]; then
        # Resolve $(PRODUCT_MODULE_NAME) to the actual module name
        sed "s/\$(PRODUCT_MODULE_NAME)/${target}/g" "$plist_src" > "$appex_dir/Contents/Info.plist"
    else
        echo "    (Warning: No Info.plist for $target)"
        cat > "$appex_dir/Contents/Info.plist" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${executable}</string>
    <key>CFBundleIdentifier</key>
    <string>com.m7archiver.${target}</string>
    <key>CFBundleName</key>
    <string>M7Archiver ${target}</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
</dict>
</plist>
PLIST_EOF
    fi

    echo "    Embedded $target.appex"
}

embed_extension "FinderExtension" "FinderExtension" \
    "Extensions/FinderExtension/Info.plist" \
    "Extensions/FinderExtension/FinderExtension.entitlements"

embed_extension "QuickLookPreviewExtension" "QuickLookPreviewExtension" \
    "Extensions/QuickLookPreviewExtension/Info.plist" \
    "Extensions/QuickLookPreviewExtension/QuickLookPreviewExtension.entitlements"
copy_archive_core_resources "$APP_DIR/Contents/PlugIns/QuickLookPreviewExtension.appex"
copy_seven_zip_cli "$APP_DIR/Contents/PlugIns/QuickLookPreviewExtension.appex"

embed_extension "QuickLookThumbnailExtension" "QuickLookThumbnailExtension" \
    "Extensions/QuickLookThumbnailExtension/Info.plist" \
    "Extensions/QuickLookThumbnailExtension/QuickLookThumbnailExtension.entitlements"
copy_archive_core_resources "$APP_DIR/Contents/PlugIns/QuickLookThumbnailExtension.appex"
copy_seven_zip_cli "$APP_DIR/Contents/PlugIns/QuickLookThumbnailExtension.appex"

cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>M7ArchiverApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.m7archiver.app</string>
    <key>CFBundleName</key>
    <string>M7Archiver</string>
    <key>CFBundleDisplayName</key>
    <string>M7Archiver</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.archive</string>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>M7Archiver URL Scheme</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>m7archiver</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> Generating development entitlements..."
DEV=.build/dev-entitlements
mkdir -p "$DEV"

# Extensions need inherit entitlement in dev (host sandbox is stripped)
cp_ext_entitlement() {
    local src="$1" dst="$2"
    if [ -f "$src" ]; then
        cp "$src" "$dst"
        /usr/libexec/PlistBuddy -c "Add :com.apple.security.inherit bool true" "$dst" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Set :com.apple.security.inherit true" "$dst"
    fi
}
cp_ext_entitlement "Extensions/FinderExtension/FinderExtension.entitlements" "$DEV/FinderExtension.plist"
cp_ext_entitlement "Extensions/QuickLookPreviewExtension/QuickLookPreviewExtension.entitlements" "$DEV/QuickLookPreviewExtension.plist"
cp_ext_entitlement "Extensions/QuickLookThumbnailExtension/QuickLookThumbnailExtension.entitlements" "$DEV/QuickLookThumbnailExtension.plist"

# Main app gets sandbox stripped for dev
if [ -f "Sources/M7ArchiverApp/M7ArchiverApp.entitlements" ]; then
    cp "Sources/M7ArchiverApp/M7ArchiverApp.entitlements" "$DEV/M7ArchiverApp.plist"
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.app-sandbox" "$DEV/M7ArchiverApp.plist" 2>/dev/null || true
fi

echo "==> Detecting code signing identity..."
CODE_SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk '{print $2}')
if [ -z "$CODE_SIGN_IDENTITY" ]; then
    echo "    No development certificate found — falling back to adhoc (extensions may not load)"
    CODE_SIGN_IDENTITY="-"
fi
echo "    Identity: $CODE_SIGN_IDENTITY"

echo "==> Signing bundles..."
sign_bundle() {
    local bundle="$1"
    local entitlements="$2"
    if [ -f "$entitlements" ]; then
        codesign --force --sign "$CODE_SIGN_IDENTITY" --entitlements "$entitlements" "$bundle"
    else
        codesign --force --sign "$CODE_SIGN_IDENTITY" "$bundle"
    fi
}

sign_embedded_7zz() {
    local bundle="$1"
    local cli="$bundle/Contents/Resources/7zz"
    if [ -f "$cli" ]; then
        codesign --force --sign "$CODE_SIGN_IDENTITY" "$cli"
    fi
}

sign_embedded_7zz "$APP_DIR"
sign_embedded_7zz "$APP_DIR/Contents/PlugIns/QuickLookPreviewExtension.appex"
sign_embedded_7zz "$APP_DIR/Contents/PlugIns/QuickLookThumbnailExtension.appex"

sign_bundle "$APP_DIR/Contents/PlugIns/FinderExtension.appex" "$DEV/FinderExtension.plist"
echo "    Signed FinderExtension.appex"
sign_bundle "$APP_DIR/Contents/PlugIns/QuickLookPreviewExtension.appex" "$DEV/QuickLookPreviewExtension.plist"
echo "    Signed QuickLookPreviewExtension.appex"
sign_bundle "$APP_DIR/Contents/PlugIns/QuickLookThumbnailExtension.appex" "$DEV/QuickLookThumbnailExtension.plist"
echo "    Signed QuickLookThumbnailExtension.appex"
sign_bundle "$APP_DIR" "$DEV/M7ArchiverApp.plist"
echo "    Signed M7Archiver.app"

echo "==> App bundle created at $APP_DIR"
echo "==> PlugIns:"
ls "$APP_DIR/Contents/PlugIns/" 2>/dev/null || echo "    (none)"
echo "==> Run: open $APP_DIR"
echo ""
echo "To register extensions with the system:"
echo "  pluginkit -a \"$APP_DIR/Contents/PlugIns/FinderExtension.appex\""
echo "  pluginkit -a \"$APP_DIR/Contents/PlugIns/QuickLookPreviewExtension.appex\""
echo "  pluginkit -a \"$APP_DIR/Contents/PlugIns/QuickLookThumbnailExtension.appex\""
