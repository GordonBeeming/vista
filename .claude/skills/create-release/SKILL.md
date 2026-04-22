---
name: create-release
description: Create a new draft release for vista. Use when the user says "create a release", "new release", "cut a release", or "ship it".
---

# Create Release

Create a new GitHub release for vista with the correct versioning.

## Steps

1. Pull latest: `but pull`
2. Determine the next version by checking existing releases:
   ```bash
   gh release list --repo gordonbeeming/vista --limit 5
   ```
3. Bump the minor version (e.g., v0.1 → v0.2). Never use a patch number in the tag.
4. Gather changes since the last release:
   ```bash
   LAST_TAG=$(gh release list --repo gordonbeeming/vista --limit 1 --json tagName --jq '.[0].tagName')
   git log ${LAST_TAG}..HEAD --oneline
   ```
5. Create the release:
   ```bash
   gh release create v{major}.{minor} \
     --repo gordonbeeming/vista \
     --target main \
     --title "v{major}.{minor} — {short description}" \
     --notes "$(cat <<'EOF'
   # vista v{major}.{minor} — {short description}

   ## What's new

   - {list changes since last release using git log}

   ## Install

   ```bash
   brew upgrade --cask gordonbeeming/tap/vista
   ```

   Or download the DMG from the assets below.
   EOF
   )"
   ```
6. The release pipeline will automatically:
   - Build + test
   - Sign with Developer ID
   - Notarize with Apple
   - Create DMG
   - Upload DMG to the release
   - Update the Homebrew tap cask
7. Report the release URL and pipeline run to the user

## Version Format

- Tags: `v{major}.{minor}` (e.g., `v0.2`) — NO patch number
- Bundle version: `{major}.{minor}.{runNumber}` — CI adds the run number as patch
- The tag `v0.2` with run number 45 produces bundle version `0.2.45`

## Important

- Never reuse or delete existing release tags
- Always bump the minor version for new releases
- Never use `.0` patch in tags (v0.2 not v0.2.0)
- The release triggers the full CI pipeline — wait for it to complete before telling the user to `brew upgrade`
