## What's new in v0.2.0

- Live desktop capture during folds, enabled by default, with a saved option to use a still image instead.
- Smoother transitions that wait for the first GPU frame before fading in the overlay.
- Improved capture restart and cleanup across lid sleep, display sleep, locking, and unlocking.
- Experimental lock-screen folding, including Apple wallpaper providers and support for other apps' overlays.
- Lock-screen capture defaults to Everything visible. Choose Selected applications to include specific apps, or System content only for a narrower capture.
- Saved application selections, a native app chooser, and diagnostics for capture and overlay placement.

Lock-screen folding is opt-in and experimental. Its switch resets when the app quits, and each lock-screen test lasts up to 90 seconds. It uses private macOS display APIs, so behavior may vary across macOS versions. Captures remain in memory; no audio is captured and no recording is saved to disk.

## Installation

Requires Apple Silicon and macOS 14 or later. Download the ZIP, extract it, and drag Lidscape.app into Applications. Quit an older copy before replacing it.

This build is ad-hoc signed and is not notarized by Apple. macOS may block its first launch. If you trust this download, use System Settings → Privacy & Security → Open Anyway after attempting to open it.

Grant Screen Recording access when prompted. Optional Apple USDZ models are not bundled; the app includes its procedural laptop preview.

The accompanying `.sha256` file can be checked with `shasum -a 256 -c <filename>.sha256` from the download directory.
