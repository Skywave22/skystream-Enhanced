# screen_brightness_windows (stub)

This package exists to keep the upstream `screen_brightness_windows` **out of
the Windows build**. It is empty on purpose and is wired in through
`dependency_overrides` in the app's `pubspec.yaml`.

## Why

The upstream plugin drives **DDC/CI** — I²C over the display link — to read and
write the *monitor's own* brightness, via `Dxva2.lib`
(`GetPhysicalMonitorsFromHMONITOR` / `GetMonitorBrightness` /
`SetMonitorBrightness`). On Windows it does this:

* **once at registration**, from its constructor, unconditionally; and
* **on every app close**, because its window-proc handles `WM_DESTROY` and
  `WM_CLOSE` by calling `OnApplicationPause()` → `SetScreenBrightness(...)`
  with **no `is_auto_reset_` guard** — unlike the `WM_SIZE` and
  `WM_ACTIVATEAPP` paths, which `ScreenBrightness().setAutoReset(false)` can
  switch off.

That close-time write is the "SkyStream resets my screen brightness on Windows"
users have reported. `setAutoReset(false)` cannot reach it.

Each failed probe also leaks a `PHYSICAL_MONITOR` handle: the throw happens
before `DestroyPhysicalMonitors`, and the `malloc` is never freed.

## Why nothing is lost

SkyStream never uses screen brightness on a desktop. The only caller is the
player's touch rail, which returns early:

```dart
// lib/features/player/presentation/vlc/vlc_player_controls.dart
if (_isDesktop) return; // no touch rails
```

So on Windows the upstream plugin's entire contribution was traffic on the
display link plus a handle leak. Android, iOS and macOS are untouched and keep
the real implementation.

## If you ever need it back

Delete the `screen_brightness_windows` entry from `dependency_overrides` in the
app's `pubspec.yaml`. Nothing else references this package.
