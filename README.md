# vista

A macOS-only, standalone replacement for Raycast's Search Screenshots. OCRs your screenshots with the Vision framework, then lets you find them by typing.

## What it does

- Watches your screenshot folder(s) and OCRs every image with Apple's on-device Vision framework.
- Summon with a user-set global hotkey. A floating panel appears with a grid of thumbnails.
- Search by filename, OCR text, or date (`name:`, `text:`, `date:yesterday`, and so on), or just type and it searches everywhere.
- Pick a result, hit enter, and it runs your chosen primary action: copy to clipboard, paste to the front app, open in Finder, or copy the OCR text.
- Pin the ones you keep coming back to. Choose your own panel size so the thumbnails are as big as you want.

Everything runs on-device. No cloud, no account, no sync. Your screenshots stay where they are.

## Install

```bash
brew install --cask gordonbeeming/tap/vista
```

Requires macOS 14 (Sonoma) or later.

## Build from source

```bash
swift build -c release
```

Or run as a real `.app` bundle during development (separate bundle id, so dev permissions don't clobber your brew-installed copy):

```bash
./Scripts/dev-run.sh
```

Launches `Distribution/Vista Dev.app` — menu bar icon, proper Info.plist, isolated TCC grants + preferences. Fast incremental debug rebuilds.

## License

Licensed under [FSL-1.1-MIT](LICENSE). Converts to MIT two years after each release.
