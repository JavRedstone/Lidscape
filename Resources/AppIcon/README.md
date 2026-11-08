# Lidscape app icon

`AppIcon.png` is a direct render of the procedural Simple model and the actual fold effect. Regenerate it with `./scripts/render-icon.sh`; it also exports the original abstract blue-and-cyan wallpaper from `PreviewArtwork` in `Sources/Lidscape.swift`. Both the laptop and its screen art are rendered in code.

Put your icon here using either filename:

- `AppIcon.png` — a square 1024 × 1024 PNG, preferably with transparency.
- `AppIcon.icns` — a ready-made macOS icon. This takes priority if both files exist.

Run `./scripts/build.sh` from the project root and reopen `build/Lidscape.app`.
The build converts the PNG to standard macOS icon sizes and embeds the icon in the app bundle. With neither file present, the app uses the default macOS application icon. The menu bar keeps its laptop symbol.
