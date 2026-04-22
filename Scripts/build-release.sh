#!/usr/bin/env bash
# =============================================================================
# build-release.sh — Build release artifacts for vista
#
# Compiles the Vista SwiftUI app with swift build -c release and assembles a
# proper .app bundle in Distribution/. The bundle is signable/notarisable;
# no CLI target to worry about (vista is GUI-only for v1).
#
# Usage:
#   ./Scripts/build-release.sh <version> <build-number>
#
# Example:
#   ./Scripts/build-release.sh 0.1 42        # → bundle version 0.1.42
# =============================================================================

set -euo pipefail

# --- Resolve project root ----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Configuration -----------------------------------------------------------
DIST_DIR="${PROJECT_ROOT}/Distribution"
GUI_TARGET="Vista"
ARCH="arm64"
BUILD_CONFIG="release"
APP_VERSION="${1:-0.1}"
BUILD_NUMBER="${2:-1}"
# Short commit SHA — baked into Info.plist so the running app can tell
# you which source produced it. Defaults to the current checkout.
GIT_COMMIT="${3:-$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")}"
# Release tag when built from a tag (e.g. "v0.1.0"); empty for dev builds.
# Lets the About / panel footer link to /releases/tag/<tag> when available.
RELEASE_TAG="${4:-}"

# --- Validate inputs ---------------------------------------------------------
if [[ ! "${APP_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo "❌ Invalid version '${APP_VERSION}' — expected major.minor (e.g. 0.1)" >&2
  exit 1
fi
if [[ ! "${BUILD_NUMBER}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "❌ Invalid build number '${BUILD_NUMBER}' — expected numeric" >&2
  exit 1
fi

# --- Clean previous artifacts ------------------------------------------------
echo "🧹 Cleaning Distribution/..."
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

# =============================================================================
# Step 1: Build the SwiftUI app
# =============================================================================
echo "🔨 Building ${GUI_TARGET} for ${ARCH} (${BUILD_CONFIG})..."

swift build \
  -c "${BUILD_CONFIG}" \
  --product "${GUI_TARGET}" \
  --arch "${ARCH}"

GUI_BIN_PATH="$(swift build -c "${BUILD_CONFIG}" --product "${GUI_TARGET}" --arch "${ARCH}" --show-bin-path)/${GUI_TARGET}"

if [[ ! -f "${GUI_BIN_PATH}" ]]; then
  echo "❌ Binary not found at ${GUI_BIN_PATH}" >&2
  exit 1
fi

# =============================================================================
# Step 2: Assemble the .app bundle
# =============================================================================
APP_BUNDLE="${DIST_DIR}/${GUI_TARGET}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "📦 Creating ${APP_BUNDLE}..."
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${GUI_BIN_PATH}" "${MACOS_DIR}/${GUI_TARGET}"
# Make sure it's executable even if the SPM output didn't preserve bits.
chmod +x "${MACOS_DIR}/${GUI_TARGET}"

# Bundle an icon if the project has one. No icon is still valid — the
# system picks a generic .app glyph — so this is a soft dependency.
if [[ -f "${PROJECT_ROOT}/Resources/AppIcon.icns" ]]; then
  cp "${PROJECT_ROOT}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  ICON_KEY=""
fi

# --- Info.plist --------------------------------------------------------------
# Generated fresh so the version/build-number match the release tag. Kept
# in sync with Sources/Vista/Info.plist — the source file is what Xcode
# would use during dev; this one is what ships.
cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.gordonbeeming.vista</string>
    <key>CFBundleName</key>
    <string>${GUI_TARGET}</string>
    <key>CFBundleDisplayName</key>
    <string>${GUI_TARGET}</string>
    <key>CFBundleExecutable</key>
    <string>${GUI_TARGET}</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}.${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    ${ICON_KEY}
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Vista indexes screenshots saved to your Desktop so you can search them by text.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Vista indexes screenshots saved in your Documents folder so you can search them by text.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Vista indexes screenshots saved in your Downloads folder so you can search them by text.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Vista uses Apple Events to paste a selected screenshot into the front application.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Gordon Beeming. Functional Source License 1.1 (FSL-1.1-MIT).</string>
    <key>VistaGitCommit</key>
    <string>${GIT_COMMIT}</string>
    <key>VistaReleaseTag</key>
    <string>${RELEASE_TAG}</string>
</dict>
</plist>
PLIST

# Also copy the entitlements alongside — the CI workflow passes this file
# to codesign --entitlements when signing.
if [[ -f "${PROJECT_ROOT}/Sources/Vista/Vista.entitlements" ]]; then
  cp "${PROJECT_ROOT}/Sources/Vista/Vista.entitlements" "${DIST_DIR}/Vista.entitlements"
fi

echo "✅ ${APP_BUNDLE}"
echo ""
echo "========================================="
echo "  Release build complete"
echo "========================================="
echo "  App bundle: ${APP_BUNDLE}"
echo "========================================="
echo ""
echo "ℹ️  Next steps:"
echo "  • codesign --deep --force --options runtime --timestamp \\"
echo "             --entitlements ${DIST_DIR}/Vista.entitlements \\"
echo "             --sign 'Developer ID Application' ${APP_BUNDLE}"
echo "  • xcrun notarytool submit <zip> --wait"
echo "  • xcrun stapler staple ${APP_BUNDLE}"
echo "  • hdiutil create -volname Vista -srcfolder ${APP_BUNDLE} …"
