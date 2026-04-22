#!/usr/bin/env bash
# =============================================================================
# dev-run.sh — Fast local dev launch as a real .app bundle.
#
# `swift run Vista` produces a bare executable with no Info.plist, so LSUIElement,
# bundle id, icon, and usage-description strings all go unread. This wraps the
# debug binary in a proper .app bundle with a dev-only bundle id
# (com.gordonbeeming.vista.dev) so it sits alongside any brew-installed vista
# without clobbering its preferences or TCC grants — dev Automation / Full Disk
# Access grants are isolated to the dev bundle.
#
# Usage: ./Scripts/dev-run.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

DEV_EXECUTABLE="VistaDev"
APP="${PROJECT_ROOT}/Distribution/Vista Dev.app"

# --- Kill any running dev instance --------------------------------------------
# Without this, `open` brings the stale process forward instead of launching the
# freshly-built binary — easy to lose 10 minutes wondering why a fix did nothing.
pkill -x "${DEV_EXECUTABLE}" 2>/dev/null || true

# --- Debug build --------------------------------------------------------------
echo "🔨 Building Vista (debug)..."
swift build --product Vista

BIN_PATH="$(swift build --product Vista --show-bin-path)/Vista"
if [[ ! -f "${BIN_PATH}" ]]; then
  echo "❌ binary not found at ${BIN_PATH}" >&2
  exit 1
fi

# --- Assemble the .app bundle -------------------------------------------------
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_PATH}" "${APP}/Contents/MacOS/${DEV_EXECUTABLE}"
chmod +x "${APP}/Contents/MacOS/${DEV_EXECUTABLE}"

if [[ -f "${PROJECT_ROOT}/Resources/AppIcon.icns" ]]; then
  cp "${PROJECT_ROOT}/Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
  ICON_KEY='<key>CFBundleIconFile</key><string>AppIcon</string>'
else
  ICON_KEY=''
fi

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Dev-only bundle id so TCC grants + UserDefaults are isolated from
         the brew-installed production copy. -->
    <key>CFBundleIdentifier</key>
    <string>com.gordonbeeming.vista.dev</string>
    <key>CFBundleName</key>
    <string>Vista Dev</string>
    <key>CFBundleDisplayName</key>
    <string>Vista Dev</string>
    <key>CFBundleExecutable</key>
    <string>${DEV_EXECUTABLE}</string>
    <key>CFBundleVersion</key>
    <string>dev</string>
    <key>CFBundleShortVersionString</key>
    <string>dev</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    ${ICON_KEY}
    <!-- Menu-bar-only, matches the shipping build. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Vista Dev indexes screenshots saved to your Desktop so you can search them by text.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Vista Dev indexes screenshots saved in your Documents folder so you can search them by text.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Vista Dev indexes screenshots saved in your Downloads folder so you can search them by text.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Vista Dev uses Apple Events to paste a selected screenshot into the front application.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Gordon Beeming. Dev build — not for distribution.</string>
    <!-- Build-badge keys so the panel footer + About window still render a
         sensible badge for the dev build. -->
    <key>VistaGitCommit</key>
    <string>$(git rev-parse --short HEAD 2>/dev/null || echo "dev")</string>
    <key>VistaReleaseTag</key>
    <string></string>
</dict>
</plist>
PLIST

# --- Launch -------------------------------------------------------------------
echo "🚀 Opening ${APP}"
open "${APP}"
