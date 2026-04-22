#!/usr/bin/env bash
# =============================================================================
# dev-run.sh — Fast local dev launch as a real .app bundle, TCC-compatible
#              with the brew-installed production copy.
#
# `swift run Vista` produces a bare executable with no Info.plist, so
# LSUIElement, bundle id, icon, and usage-description strings all go
# unread. This wraps the debug binary in Distribution/Vista.app (same
# bundle id as the brew-installed copy — com.gordonbeeming.vista) so
# macOS treats dev and prod as the same app for TCC: grant Automation
# or Full Disk Access once in either build and it carries across.
#
# Because the bundle id matches the production copy, we must never run
# both at once (same bundle id = they'd fight over preferences, TCC
# entries, hotkey registration). The script pkills both first, launches
# the freshly-built dev bundle, then tails the on-disk log for you.
#
# Usage:
#   ./Scripts/dev-run.sh                 # build, launch, tail log
#   ./Scripts/dev-run.sh --no-tail       # build + launch, skip tail
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

TAIL=1
for arg in "$@"; do
  case "$arg" in
    --no-tail) TAIL=0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 1 ;;
  esac
done

EXECUTABLE="Vista"
BUNDLE_ID="com.gordonbeeming.vista"
APP="${PROJECT_ROOT}/Distribution/Vista.app"
LOG="${HOME}/Library/Logs/Vista/vista.log"

# --- Kill any running instance (brew-installed or any previous dev) ----------
# Both the current executable name (`Vista`) and the legacy one from earlier
# dev-run.sh versions (`VistaDev`) need to go — they're different executables
# but share the com.gordonbeeming.vista* bundle id family and would fight over
# UserDefaults, the hotkey, and the menu bar icon. Silent fail if nothing's
# running.
pkill -x "Vista" 2>/dev/null || true
pkill -x "VistaDev" 2>/dev/null || true
# Give launchd a moment to tear down before we `open` the new one —
# otherwise macOS may foreground the dying process instead of launching ours.
sleep 0.5

# --- Clean up the legacy dev bundle ------------------------------------------
# Previous versions of this script produced Distribution/Vista Dev.app with a
# different bundle id (com.gordonbeeming.vista.dev). It's no longer used; left
# on disk it confuses Launch Services and shows up as a stale app in Spotlight.
rm -rf "${PROJECT_ROOT}/Distribution/Vista Dev.app"

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
cp "${BIN_PATH}" "${APP}/Contents/MacOS/${EXECUTABLE}"
chmod +x "${APP}/Contents/MacOS/${EXECUTABLE}"

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
    <!-- Same bundle id as the brew-installed copy so TCC grants and
         UserDefaults preferences are shared. Don't run both at once. -->
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>Vista</string>
    <key>CFBundleDisplayName</key>
    <string>Vista (dev)</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE}</string>
    <key>CFBundleVersion</key>
    <string>dev</string>
    <key>CFBundleShortVersionString</key>
    <string>dev</string>
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
    <string>Copyright © 2026 Gordon Beeming. Dev build — not for distribution.</string>
    <key>VistaGitCommit</key>
    <string>$(git rev-parse --short HEAD 2>/dev/null || echo "dev")</string>
    <key>VistaReleaseTag</key>
    <string></string>
</dict>
</plist>
PLIST

# --- Ad-hoc sign with a stable identifier ------------------------------------
# Without a signature, TCC sees a new "app" on every rebuild and nags the
# user to re-grant Automation / FDA each time. `codesign -s - --identifier`
# produces an ad-hoc signature bound to the explicit identifier, which TCC
# can use as a stable key across builds.
codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP}" >/dev/null 2>&1 || true

# --- Launch -------------------------------------------------------------------
echo "🚀 Opening ${APP}"
# -n forces a fresh instance even if Launch Services thinks the same
# bundle id is already running somewhere — defends against LS caching
# the brew-installed path.
open -n "${APP}"

# --- Tail the log -------------------------------------------------------------
if [[ "${TAIL}" -eq 1 ]]; then
  mkdir -p "$(dirname "${LOG}")"
  # Create the file if the app hasn't written it yet, so tail doesn't error.
  touch "${LOG}"
  echo ""
  echo "📜 Tailing ${LOG} (Ctrl-C to stop — app keeps running)"
  echo ""
  tail -f "${LOG}"
fi
