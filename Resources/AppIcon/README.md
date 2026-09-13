# Lidscape app icon

Put your icon here using either filename:

- `AppIcon.png` — a square 1024 × 1024 PNG, preferably with transparency.
- `AppIcon.icns` — a ready-made macOS icon. This takes priority if both files exist.

Run `./scripts/build.sh` from the project root and reopen `build/Lidscape.app`.
The build converts the PNG to standard macOS icon sizes and embeds the icon in the app bundle. With neither file present, the app uses the default macOS application icon. The menu bar keeps its laptop symbol.
