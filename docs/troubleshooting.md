# Troubleshooting

[Guide home](README.md)

## Desktop effect stays off

Read the status below the window header or in the laptop menu. A preview that works does not prove desktop capture is authorized.

- **Permission needed:** enable `/Applications/Lidscape.app` in Screen Recording settings, then quit and reopen it if prompted.
- **Checking access:** wait for the capture check to finish. A failure message includes the reason.
- **No lid sensor:** the preview remains available, but physical-lid animation requires a valid sensor reading.
- **Ready:** the app is waiting for the physical lid to cross its starting threshold. The preview slider does not control the actual desktop.

If Lidscape is absent from Screen Recording settings, use **+** to add the Applications copy. Keep one installed copy and launch it consistently. Replacing a build with a different signing identity may require fresh approval; the build script prefers an available Apple Development identity to keep signing consistent.

## It resets after I stop moving

This is **Hold to reset**, enabled by default. Increase Reset delay or disable Hold to reset to keep the folded projection visible. If Auto-calibrate is on, it can still request a return to normal before adopting a new reference.

## My starting angle changes

Auto-calibration defaults to on. It adopts an eligible physical angle after the Calibration delay, normally five seconds. Disable it to keep the reference fixed, or recalibrate manually from your preferred position.

## Playback stops before the lid is closed

Check **Preview zero**. Edge-on to eyes ends the preview at the configured viewing horizon; choose **Lid closed** for a physical 0° endpoint. The full animation can be invisible from Your viewpoint while the lid is closing; Inspect in 3D lets you inspect its physical position.

## The selected model looks like Simple

Apple USDZ assets are not included in the repository. Without compatible local files, the renderer uses the procedural fallback. See [optional model setup](../Resources/Models/README.md).

## Motion looks uneven

First distinguish the **preview** from the **physical lid**. Try the preview play button, then a slow manual drag. The preview uses GPU rendering and display-synchronized smoothing; physical motion also depends on HID readings sampled separately at 60 Hz.

Increase Smoothing slightly if sensor steps are visible. A larger value makes motion softer but slower to follow your hand. A display capped at 60 Hz cannot show 120 frames per second. System load and graphics workload also affect frame pacing.

If performance degrades over time, report which path is affected, roughly how long the app has been running, the model/color, whether hold reset or auto-calibration is enabled, and whether closing the preview window helps. The current app explicitly disposes overlays and display links and avoids caching changing intermediate frames. A two-minute stress test is useful evidence, not a guarantee for every long-running workload.

Developers can run:

```sh
./scripts/test.sh
LIDSCAPE_BENCHMARK_SECONDS=120 ./scripts/benchmark.sh
```

## The Dock icon disappeared

Click the laptop menu bar icon → **Open Lidscape…**, then enable **Settings → App behavior → Show Dock icon**. You can quit from the same menu.

## Screen goes to sleep when closed

That is normal macOS behavior. Lidscape does not prevent lid sleep or draw over the secure login screen.
