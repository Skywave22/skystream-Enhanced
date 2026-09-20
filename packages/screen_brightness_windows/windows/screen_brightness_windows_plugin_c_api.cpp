#include "include/screen_brightness_windows/screen_brightness_windows_plugin_c_api.h"

// Deliberately registers nothing.
//
// The upstream plugin's constructor issues DDC/CI (I2C over the display link)
// to read the monitor's own brightness, and installs a window-proc delegate
// that writes it back on WM_DESTROY and WM_CLOSE with no is_auto_reset_ guard.
// SkyStream never uses screen brightness on desktop -- the only caller returns
// early there -- so that traffic bought nothing and cost users a reset screen.
//
// The entry point still exists, and the package still declares a Windows
// plugin, so the Flutter tool's `default_package` lookup for
// screen_brightness resolves cleanly and no warning is emitted. It simply does
// not construct a plugin, which means no DDC/CI and no window-proc delegate.
//
// See README.md.
void ScreenBrightnessWindowsPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  (void)registrar;
}
