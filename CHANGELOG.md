# Changelogs - Unreleased

### ✨ *New Features & Enhancements*

#### 🖼️ Icons
- **The macOS app icon is now the rounded-square shape macOS expects**, instead of a plain square. macOS doesn't round app icons the way iOS does — the shape has to be part of the artwork — so SkyStream had been the one square icon in the Dock.
- **The Windows icon now ships all eight sizes** (16 through 256) instead of only 256. Windows was downscaling a single large image on the fly, which is why it looked soft in the taskbar, title bar and Alt-Tab.

#### 🛠️ Stability
- **Fixed: SkyStream no longer changes your monitor's brightness on Windows.** The bundled screen-brightness plugin was sending DDC/CI commands — the protocol that controls the monitor's own hardware brightness over the display cable — to your display: once at startup, again on every window activation, and once more *every time the app closed*. That last one is what reset people's brightness, and it could not be switched off. SkyStream never uses screen brightness on desktop in the first place (it's a phone-only touch gesture), so the plugin is now kept out of the Windows build entirely. Android, iOS and macOS are unaffected and keep the feature.
- **Cloudflare should now work on installed Windows builds.** WebView2 was being asked to keep its working files inside the installation directory, which on a normal install is `C:\Program Files` and isn't writable by a standard user — so it could fail before it started. It now uses your app-data folder like every other part of the app. If you install SkyStream on Windows rather than running it from source, this may be the first time Cloudflare-protected sources have worked at all.
- **Cloudflare bypass no longer wedges itself.** A WebView that failed to start could hold the single solve slot forever, silently disabling every Cloudflare-protected source for the rest of the session. It now gives up after 30 seconds and hands the slot back.
- **Cloudflare failures no longer hide the real error.** On Linux, and on any platform where the system WebView cannot start, a failed bypass used to replace the site's actual response with an empty one — so the logs showed nothing useful. The real status now survives.
- **Fewer repeated Cloudflare challenges.** When Cloudflare rotated its clearance cookie, the refreshed cookie was not being handed back to the network layer, so the next request was challenged again. It is now.

#### 🎛️ Player
- **Hardware Decoding is now shown only on Android**, which is the only platform where the switch reaches a decoder. On Windows and Linux libVLC pins hardware decoding off for the rendering path the app uses, and on iOS and macOS decoding runs on VideoToolbox regardless of the setting — so on those four the row was reporting a decoder the app was not using. Playback itself is unchanged everywhere.

#### 🎨 Appearance & Window
- **Dark is now the default theme.** It used to depend on the device: dark on a television, and whatever the OS was set to everywhere else. If you have never picked a theme in Settings, the app will now open dark — **System** and **Light** are still there under Settings › Appearance.
- **Full screen mode is remembered between sessions.** Leaving the app in full screen (Settings › General, the ten-foot TV layout) brings it back that way on the next launch, instead of reverting to the normal layout every time.
- **Removed the undocumented `--full-screen` launch flag** and its aliases. They were internal testing switches that reached a release by accident, and the setting above replaces them: toggle full screen once and it sticks.

#### ⬇️ Downloads
- **Download location** setting with a native folder picker; the chosen path is used when saving and locating files.
- **Queue limit** (1–10 concurrent downloads) via a native holding queue.
- **Segments per file** (1–8) using `ParallelDownloadTask` to accelerate large downloads.
- **Pause all** and **Resume all** controls in the Downloads tab.
- Multi-**select** mode (long-press / checklist) with **Delete selected**, alongside the existing per-item pause/resume/delete.

---

# Changelogs - v2.7.6

### ✨ *New Features & Enhancements*

#### 🎬 Media Player & Subtitle Enhancements (PR #75 by @arranoust & PR #81 by @likhithkrishna1103)
- **Player Control Toggles** – Added customizable visibility toggles for player control buttons in player settings.
- **Cache Management** – Added dedicated setting to clear image and video cache.
- **Hotstar-Style Subtitles** – Replaced custom subtitle view with configurable Hotstar-style subtitle rendering and improved subtitle parsing robustness.

#### 📱 iOS Experience & Download Management (PR #84 by @Fares669)
- **iOS Live Activity & Background Downloads** – Integrated Live Activity for active downloads and iOS background task processing to ensure download tasks continue reliably when the app is backgrounded.
- **Detailed Download Progress** – Real-time download percentage and transferred file size indicators with improved label positioning.

#### 📑 Episode Selection & Watch History (PR #84 by @Fares669)
- **Multi-Episode Selection & Watched States** – Easily select multiple episodes to batch-mark as watched or unwatched.
- **Offline Watch History Sync** – Automatically sync playback of downloaded offline episodes with your episode watch history.
- **Improved Action Bar** – Replaced episode selection SnackBar with a dedicated bottom action bar and compact buttons.
- **Quick Copy Title** – Long press on any media title to quickly copy it to clipboard.

#### ⚙️ Poster Customization & Extension Settings (PR #74 by @arranoust & PR #84 by @Fares669)
- **Poster Title Positioning** – Added customizable title placement options (top, bottom, overlay) for multimedia poster cards.
- **Redesigned Extension Settings** – New dedicated plugin settings screen supporting conditional and script-defined plugin parameters, dynamic loading, and improved runtime cache handling.

---

### 🐞 *Bug Fixes & System Stability*
- 🛠️ Fixed SnackBar contrast and theme colors across settings and download screens.
- 🛠️ Fixed extension settings runtime cache handling and plugin provider initialization.
