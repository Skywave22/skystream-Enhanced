# Changelogs - Unreleased

### ✨ *New Features & Enhancements*

#### 🆕 Cross-Plugin "Stream" Tab
- New **Stream** navigation destination next to Library (desktop/TV sidebar and mobile bottom bar), backed by TMDB (trending movies + popular TV shows).
- Opening a movie or TV episode aggregates streaming links from **all installed plugins** into a single source picker. Titles are matched strictly by TMDB/IMDb ID, falling back to normalized title + media type + year — plugins that don't have the title contribute no links.
- Aggregated links are passed into the player; the in-player **Sources** panel lists every link and supports switching across plugins.
- Each source shows the originating plugin name as a small label.

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
