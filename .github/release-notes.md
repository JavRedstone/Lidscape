## What's new in v0.3.0

- Redesigned settings with a native macOS sidebar, grouped controls, and focused panes for General, Appearance, Fold Effect, Calibration, Lock Screen, and Activity.
- Light, Dark, and System appearance choices. System correctly follows macOS after switching from an explicit appearance.
- An upgraded menu-bar control panel with live lid status, quick controls, and calibration.
- Colored Enable/Pause controls with native Liquid Glass on macOS 26 and later, stable dimensions, and improved toolbar spacing. Earlier macOS versions use native bordered controls.
- Activity charts for live lid and starting angles, daily fold counts and time, and the last seven days of folds. Recent history combines calibration changes with enable/pause events and their reasons.
- Vertical event markers on the live graph, with nearby changes grouped to prevent overlap. Select a group below the graph for exact timestamps.
- Original abstract blue-and-cyan artwork throughout the app icon, preview, and demonstration, replacing the landscape image.
- Automatic preview model selection, without manual model/color setup.

## Fixes

- Lock-screen folding now saves across launches and no longer switches off after a 90-second test period.
- Corrected capture selection and overlay Space ordering so included app overlays can fold with the lock screen.
- Fixed a lock-screen crash caused by invalid AppKit window IDs.
- Improved capture refresh, lock/unlock detection, full-screen coverage, and readable diagnostics with copyable technical details and last-fold results.
- Isolated test preferences to prevent checks from overwriting the app's saved settings.

Lock-screen folding uses private macOS display APIs, so behavior can vary across macOS versions. Captures stay in memory; no audio is captured and no recording is saved to disk. Activity history is stored locally, starts with this version, and can be cleared in Activity. Daily totals are retained for 30 days; up to 200 angle changes and 200 enable/pause events are retained. The live angle graph covers the current app session.

## Installation

Requires Apple Silicon and macOS 14 or later. Download the ZIP, extract it, and drag Lidscape.app into Applications. Quit an older copy before replacing it.

This build is ad-hoc signed and is not notarized by Apple. macOS may block its first launch. If you trust this download, use System Settings → Privacy & Security → Open Anyway after attempting to open it.

Grant Screen Recording access when prompted. Optional Apple USDZ models are not bundled; the app includes its procedural laptop preview.

The accompanying `.sha256` file can be checked with `shasum -a 256 -c <filename>.sha256` from the download directory.
