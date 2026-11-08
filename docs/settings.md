# Effect settings and calibration

[Guide home](README.md) · [Troubleshooting](troubleshooting.md)

Choose General, Appearance, Fold Effect, Calibration, Lock Screen, or Activity in the sidebar. Controls use native grouped settings. The toolbar offers Pause or Enable for the desktop effect.

Settings save automatically and survive quitting. To see a slider’s effect without moving your real lid, keep the preview partly folded while adjusting it.

**General → Live desktop capture** defaults to on and keeps content moving during the fold. Turn it off to capture one still image per fold and stop capture after that first frame. This preference saves across launches; Reset settings turns it back on.

## Lock-screen content

**Lock Screen → Include** saves across launches:

- **Everything visible** (default): captures the built-in display, including other apps’ overlays and overlays that appear after capture starts. Lidscape’s own windows are excluded to prevent visual feedback.
- **Selected applications**: includes system content plus the visible windows and overlays of apps you choose. Click **Choose applications…** to select one or more apps, then use the minus button beside an app to remove it. The selection saves across launches. The visible window list refreshes during the fold, including overlays that appear later.
- **System content only**: the login-window interface and known Apple wallpaper providers.

This choice applies while **Lock-screen fold** is enabled. The switch, content choice, and application list all save across launches; there is no time limit. Reset settings returns to Everything visible and clears the application list.

## Match your viewing position

![Distance, manual calibration, automatic calibration, and preview angle mode](images/guide/calibration.png)

1. Set **Distance** to the horizontal distance from your eyes to the hinge plane. The default is 55 cm.
2. Sit in your normal working position and adjust the screen comfortably.
3. Look straight at the screen center and click **Calibrate from current lid**.

Calibration adopts that physical lid angle as **Start below** and estimates eye height assuming your view is perpendicular to the center of the screen. It does not measure your head or eyes. Recalibrate after changing posture or distance. Manual calibration requires a lid-sensor reading between 60° and 150°.

**Manual eye height** lets you adjust the estimate yourself. Height is measured above the hinge; it is not your height above the desk or floor.

## Automatically adopt a new working angle

**Auto-calibrate when the lid settles** defaults to on for new settings. Existing saved choices are retained.

- **Calibration delay — 5 seconds:** leave the physical lid still for this long to adopt its angle. Adjust from 0.5–8 seconds.
- **Minimum calibration angle — 30°:** an additional lower limit for automatic calibration. The supported sensor range is still 60–150°, so a minimum below 60° does not extend it.

For example, move the screen from 90° to 110°, then leave it still for five seconds. Lidscape adopts 110° as its new starting angle and estimates a new eye height. It calibrates once per hold; another movement rearms it.

Below the configured minimum, automatic calibration is blocked. After crossing below it, the lid must rise 1.5° above the minimum and complete a fresh delay. This limit does not block the fold effect or hold reset.

## Tune the appearance and response

![Smoothing, blur, fade, hold reset, and starting angle](images/guide/fold-effect.png)

| Control | Starting value | How to use it |
| --- | --- | --- |
| Smoothing | 55 ms | Increase for softer motion; decrease for a faster response. Range: 25–140 ms. More smoothing also adds lag. |
| Blur | 100% | Adjust the frosting that increases toward the top as the lid folds. 0% disables it; maximum 200%. |
| Fade to black | 100% | Adjust darkening, strongest toward the top. 0% disables it; maximum 200%. |
| Hold to reset | On | Restore normal perspective and remove blur/fade when the lid stays still. |
| Reset delay | 1 second | How long to hold still before returning to normal. Range: 0.5–3 seconds. |
| Start below | 90° | Set the reference angle and the threshold for starting the desktop effect. Calibration also updates this. |

The real effect enters 1.5° below Start below and exits 1.5° above it. This separation prevents small sensor fluctuations from repeatedly turning it on and off.

## Know which reset you are seeing

**Hold reset changes the image.** Stop moving, wait for Reset delay, and perspective, blur, and fading ease away. The overlay disappears so you can use your live desktop at that angle. Your calibrated reference stays the same. Movement within the effect range reactivates the projection.

**Auto-calibration changes the reference angle.** It waits for Calibration delay and adopts a new working angle. If the overlay is active, it first completes a return to normal. This can happen even if Hold to reset is off.

The timers are independent. With defaults, the image can return to normal after one second, while calibration waits five seconds before adopting the angle. Turn off Auto-calibrate if you want to keep one fixed reference position; turn off Hold to reset if you want the projection to remain visible while stationary.

## Restore defaults

![Reset settings button](images/guide/reset-settings.png)

In **General**, click **Reset settings…** and confirm to restore effect, calibration, preview, and Dock/startup-animation preferences. The reset is saved immediately and Desktop effect is paused for the current session. It does not revoke Screen Recording permission or unregister Launch at login; manage those separately.

## Appearance

Choose **Appearance** in the sidebar, then **Light**, **Dark**, or **System**. System follows your Mac. The choice saves and applies to Lidscape windows, the menu panel, and native dialogs. Dock icon visibility is also in this pane.

## Activity

**Activity** shows live lid and starting angles over the last five minutes, with orange vertical pause markers and green enable markers. Labels appear in a separate event strip below the chart. Changes within 12 seconds share a marker; selecting a group shows every exact timestamp. It also shows today’s fold count and time folding, a seven-day fold chart, and a combined recent-history timeline. The timeline includes successful enables, pauses, and starting-angle changes, with timestamps and reasons. Launch-time enables and pauses caused by lost capture access are identified. Angle changes are labeled as automatic calibration, manual calibration, or manual adjustment. Nearby slider adjustments are combined into one change.

History starts when this version is installed; earlier usage is not reconstructed. Daily totals are saved locally for 30 days and up to 200 angle changes and 200 enable/pause events are retained. The live graph is kept only for the current app session. **Clear activity history…** removes saved totals and history events after confirmation. New activity then records normally.

## Lock-screen status

The Lock Screen pane shows whether the overlay is ready, any capture error, and the last fold’s capture time, wallpaper/app window counts, rendering result, and visibility. **Technical details** holds the WindowServer information. **Copy diagnostics** copies the current status and last-fold results for troubleshooting.
