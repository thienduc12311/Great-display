#!/bin/bash
# Builds GreatDisplay.app into dist/.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CONFIGURATION="${1:-release}"
APP_NAME="GreatDisplay"
APP="dist/${APP_NAME}.app"

# Version metadata. CI passes these from the release tag; local builds fall
# back to the latest tag (or 0.0.0-dev) and the commit count.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# ARCHS="arm64 x86_64" produces a universal binary (needs full Xcode).
# Empty builds for the host architecture only.
ARCH_FLAGS=()
for arch in ${ARCHS:-}; do
    ARCH_FLAGS+=(--arch "${arch}")
done

echo "==> Building ${APP_NAME} ${VERSION} (${BUILD_NUMBER}), ${CONFIGURATION}, archs: ${ARCHS:-host}"
swift build -c "${CONFIGURATION}" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_PATH="$(swift build -c "${CONFIGURATION}" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "==> Rendering icon"
ICONSET="dist/AppIcon.iconset"
rm -rf "${ICONSET}"
swift Scripts/make_icon.swift "${ICONSET}"
iconutil -c icns "${ICONSET}" -o "dist/AppIcon.icns"

echo "==> Assembling bundle"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_PATH}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp "dist/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Great Display</string>
    <key>CFBundleExecutable</key>
    <string>GreatDisplay</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>app.greatdisplay.GreatDisplay</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>GreatDisplay</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>app.greatdisplay.GreatDisplay</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>greatdisplay</string>
            </array>
        </dict>
    </array>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © Great Display contributors. MIT License.</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Signing"
# Privacy grants (Accessibility, Screen Recording) are bound to the app's
# designated requirement. An ad-hoc signature's default requirement is its
# cdhash, which changes on every build and silently invalidates the grant
# while System Settings still shows the app as enabled. Use a real signing
# identity when one is available (SIGN_IDENTITY or the first valid one);
# otherwise sign ad-hoc with an identifier-based requirement that stays the
# same across rebuilds.
# SIGN_IDENTITY=- forces the ad-hoc path.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/ {print $2; exit}')}"
if [[ -n "${SIGN_IDENTITY:-}" && "${SIGN_IDENTITY}" != "-" ]]; then
    # Explicit identity (release builds): hardened runtime + secure timestamp,
    # as notarization requires. Fail loudly.
    echo "    identity: ${IDENTITY}"
    codesign --force --deep --options runtime --timestamp --sign "${IDENTITY}" "${APP}"
elif [[ -n "${IDENTITY}" && "${IDENTITY}" != "-" ]]; then
    echo "    identity: ${IDENTITY}"
    codesign --force --deep --options runtime --sign "${IDENTITY}" "${APP}" >/dev/null 2>&1 || true
else
    echo "    ad-hoc, designated requirement: identifier app.greatdisplay.GreatDisplay"
    codesign --force --deep --sign - \
        --requirements '=designated => identifier "app.greatdisplay.GreatDisplay"' \
        "${APP}" >/dev/null 2>&1 || true
fi
# Local builds carry on without a valid signature (the app still runs, but
# privacy grants will not stick). REQUIRE_VALID_SIGNATURE=1 makes it an error;
# the workflows set it so a broken signature cannot be packaged and published.
if codesign --verify --deep --strict "${APP}" >/dev/null 2>&1; then
    echo "    signature verified"
elif [[ "${REQUIRE_VALID_SIGNATURE:-}" == "1" ]]; then
    echo "error: ${APP} has no valid code signature" >&2
    codesign --verify --deep --strict --verbose=2 "${APP}" >&2 || true
    exit 1
else
    echo "    warning: signature verification failed" >&2
fi

echo "==> Built ${APP}"
echo "    Launch: open \"${APP}\""
echo "    Probe:  \"${APP}/Contents/MacOS/${APP_NAME}\" --probe"
