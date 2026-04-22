#!/usr/bin/env bash
# =============================================================================
# package-for-homebrew.sh — Build a DMG and emit a ready-to-paste Homebrew cask
#
# Runs after build-release.sh. Wraps Distribution/Vista.app in a DMG, computes
# its SHA256, and prints the cask definition. The CI workflow does its own
# DMG + cask plumbing; this script exists for local verification.
#
# Usage:
#   ./Scripts/package-for-homebrew.sh <version>
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>" >&2
  echo "Example: $0 0.1.0" >&2
  exit 1
fi

VERSION="$1"
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "❌ Invalid version '${VERSION}'" >&2
  exit 1
fi

DIST_DIR="${PROJECT_ROOT}/Distribution"
APP_BUNDLE="${DIST_DIR}/Vista.app"
DMG_PATH="${DIST_DIR}/Vista-${VERSION}.dmg"
REPO="gordonbeeming/vista"

if [[ ! -d "${APP_BUNDLE}" ]]; then
  echo "❌ ${APP_BUNDLE} missing — run Scripts/build-release.sh first." >&2
  exit 1
fi

echo "💿 Creating DMG ${DMG_PATH}..."
# UDZO = compressed read-only, the standard distribution format.
hdiutil create \
  -volname "Vista" \
  -srcfolder "${APP_BUNDLE}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

SHA256="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"

echo ""
echo "🔑 SHA256: ${SHA256}"
echo ""
echo "========================================="
echo "  Homebrew Cask (paste into gordonbeeming/homebrew-tap/Casks/vista.rb)"
echo "========================================="
cat <<CASK

cask "vista" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/${REPO}/releases/download/v#{version}/Vista-#{version}.dmg"
  name "Vista"
  desc "Search your screenshots by text, name or date — OCR-powered"
  homepage "https://github.com/${REPO}"

  depends_on macos: ">= :sonoma"

  app "Vista.app"

  zap trash: [
    "~/Library/Application Support/Vista",
    "~/Library/Caches/com.gordonbeeming.vista",
    "~/Library/Preferences/com.gordonbeeming.vista.plist",
  ]
end
CASK
echo ""
echo "ℹ️  Next steps (CI does this automatically on release):"
echo "  1. Upload ${DMG_PATH} as a release asset for v${VERSION}"
echo "  2. Commit the cask above to gordonbeeming/homebrew-tap"
echo "  3. Verify:  brew install --cask gordonbeeming/tap/vista"
