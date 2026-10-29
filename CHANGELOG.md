# Changelogs - v2.9.0

### ✨ *New Features & Enhancements*

#### 🧩 CloudStream Extensions
- **CloudStream (.cs3) extensions on every platform** – Install and run CloudStream extensions on Android, iOS, macOS, Windows and Linux. Their providers appear on Home, in search and in the provider list.
- **Repositories** – Add a repository by its URL (repo.json or plugins.json), a cloudstreamrepo:// link or a shortcode. MegaRepo is supported, Check Updates shows what changed, and each extension can be updated or removed.
- **Extension settings** – An extension's own settings open in SkyStream on every platform and take effect without restarting the app. Extensions' own dialogs and pages open in SkyStream too.
- **Full-screen extension windows** – Extensions that open a full-screen page, games included, work on every platform, and Back closes them.
- **One switch** – Turn CloudStream off entirely in Settings: no extension loads and their providers are hidden everywhere. Nothing is uninstalled.
- **Richer details** – A CloudStream title's page shows everything its extension provides: its logo, score, content rating, status and tags; cast with voice actors; trailers; more titles from the same extension; when the next episode airs; named seasons; and each episode's rating, runtime and air date. A title not out yet says Coming soon. Tracking and skip times now get the title's MAL, AniList, IMDb and TMDB ids.

#### 🛡️ Bot Checks (Cloudflare and Others)
- **SkyStream's own browser engine** – Bot checks are now cleared in each platform's own browser engine on every platform, Linux included, instead of the old WebView plugin.
- **Checks cleared for you** – SkyStream ticks the checkbox itself where it can. When a site needs you, its check opens right where you are.
- **One check per site** – A site cleared once works for SkyStream plugins, CloudStream extensions, Nuvio scrapers and Stremio add-ons alike, and stays cleared across restarts until the site asks again.
- **See each site's check** – Search, Explore and Home show the sites that need a check, with Verify for one site or all of them. A site can be set not to open its check by itself.
- **Clearer reasons** – A site that blocks VPNs, keeps asking, can't be reached, or needs a newer Android System WebView says so.
- **Moved sites followed** – When a site moves to a new address, SkyStream follows it.
- **More check vendors** – DDoS-Guard and other vendors are handled, and a captcha an extension asks for is shown to you to solve.

#### 🔎 Search
- **Universal search** – One search bar for SkyStream, CloudStream, Stremio and Nuvio: a section for each Stremio add-on and one for Nuvio, with every result tagged with where it came from.
- **Search in every language** – Titles are found whatever their accents, letter forms, digits or spacing: "pokemon" finds "Pokémon", and Arabic, Persian, Urdu, Hebrew, Turkish and Indian-language titles match the way they are typed. Japanese, Chinese and Thai titles written without spaces are found by any part of the name, and Korean ones with or without spaces. A provider whose titles are all in another script shows them instead of nothing (PR #127 by @1eren0).
- **Traditional and Simplified Chinese** – A search in either finds titles written in the other: 复仇者联盟 finds 復仇者聯盟, and 活着 finds 活著.

#### 🎬 Player & Playback
- **Volume and brightness swipes like VLC** – Both follow your finger with no lag. The volume boost above 100% shows in orange, and a swipe from below 100% stops there first: swipe up again to go past it.
- **Volume keys** – On Android the volume keys change the video's volume even while it is paused. On a desktop keyboard, holding a volume key keeps stepping.
- **Orientation** – Leaving the player returns to your device's orientation, with the rotation lock respected.
- **Rotate button** – On phones and tablets, a Rotate button turns the player between landscape and portrait. The player still turns to fit each video first; your choice holds for the rest of that video, and the next one fits itself again. It can be hidden in Player Controls. iPads and Android 16 tablets don't let apps turn the screen, so they don't have it.
- **Faster playback** – Playback speed now goes up to 4x, with 3x and 4x among the quick choices.
- **New player controls** – Frosted controls, and one Options button for sources, audio, subtitles and episodes. The volume and episode buttons can be hidden in Player Controls (PR #121 by @likhithkrishna1103-tech).
- **Held keys** – Holding left or right on a keyboard or a TV remote, or J/L on a keyboard, keeps seeking (PR #121 by @likhithkrishna1103-tech).
- **Audio language** – Choose the language videos start in, in Player settings. A video with an audio track in that language starts on it, including after a source change and on the next episode; one without it plays its own default. A track you pick from Audio in the player stays for the rest of that video (PR #130 by @1eren0).
- **More languages** – Persian, Filipino, Thai and Azerbaijani can be chosen as the audio language and in subtitle search, and SubSource now finds Chinese subtitles.
- **Subtitles from Stremio add-ons** – The player's subtitle search also asks your Stremio subtitle add-ons, and OpenSubtitles' own Stremio add-on, so a film or an episode with an IMDb id finds subtitles with no key or account.
- **Subtitle style in the player** – A Subtitle style page in the player's Subtitles tab sets the size, colours, background, outline, position, bold, font, text opacity and encoding, on every device including TV; Settings has the same choices. Subtitle files change at once. Subtitles inside the video change from their next line, and take bold, font, text opacity and encoding the next time the player opens (PR #133 by @1eren0).
- **Play Stremio titles from their page** – When the add-on a title came from also brings its links, as CNCVerse Bridge does, the title's page has a Play button (Resume once started, and the next episode for a show), its episodes are laid out like a CloudStream title's and play with a tap, and the player goes on to the next episode from the same add-on. Holding an episode searches every add-on for it, as Search Stremio add-ons does.
- **Choose a stream's quality** – A stream that offers several qualities (HLS) gets a Quality tab in the player's Options: Auto, or any quality it offers, with every audio track kept. Your choice holds for the rest of that viewing, through source changes and the next episodes. Auto now follows your Wi-Fi & Wired and Mobile quality preferences, and such streams are listed at your preferred quality instead of last.
- **Videos start sooner** – A video starts once a second of it has loaded, instead of three: MP4 files start about a second sooner.
- **Read-ahead sized for each video** – The player reads about three minutes ahead (one on mobile data, six for very high-bitrate files), worked out from the video's bitrate, and never more than this device's memory allows. Network buffer in Player settings now offers Auto (recommended), which everyone starts on, or a fixed size.
- **Fewer stalls on a weak connection** – On HLS streams, Auto quality steps down before the video runs out, not after.
- **Live streams closer to live, with a rewind** – Live streams start closer to the live edge. On a live stream that keeps the last minutes, the progress bar covers them: step or drag back to catch what you missed, see how far behind live you are, and tap LIVE to catch up.
- **One buffering spinner, everywhere** – It shows when the picture freezes, never while you drag the progress bar, and goes the moment the video moves again.
- **Streams come back by themselves** – When the connection drops, the server stalls or the network goes, the last picture stays on screen with "Reconnecting…" or "Waiting for network…", and playback picks up where it stopped as soon as the stream is back. A source is only given up on when its server says it's gone, or another source's server answers while this one stays silent.
- **Slow starts get their time** – A stream that is still loading isn't abandoned at 30 seconds; one that shows no sign of life is.
- **Torrents start on the right buffer** – TorrServer now gets the buffer size SkyStream chooses for each film, instead of running on its 64 MB default, and the film is no longer held twice in memory. While a torrent prepares, the screen shows its peers, speed and how much is loaded.
- **Season packs play the episode you picked** from Stremio add-ons, instead of the pack's first file.

#### 🖥️ Interface
- **Navigation bar** – A new frosted navigation bar on phones (PR #121 by @likhithkrishna1103-tech).

#### 🔐 Accounts
- **MyAnimeList and AniList sign-in inside SkyStream** – Signing in happens in the app, on every platform.
- **Trakt's new sign-in** – Trakt now signs in through Trakt's new sign-in page. If you were signed in to Trakt before, you may be asked to connect once more.
- **Simkl's new sign-in** – Connecting Simkl now uses Simkl's new sign-in (AUTH V2), the same code to enter on simkl.com/pin. Simkl retires the old one around April 2027; if you're already connected, you stay connected.

---

### 🐞 *Bug Fixes & System Stability*
- 🛠️ **Fixed: some CloudStream extensions worked only partly** – An extension's results are now read one by one: a search result, a home entry, an episode, a link or a subtitle an extension leaves out no longer loses the rest of the page with it.
- 🛠️ **Fixed: a CloudStream extension's links were given up on too early** – The engine stopped waiting after 30 seconds and left the extension with nothing to play. It waits as long as CloudStream does now (two minutes).
- 🛠️ **Fixed: an extension's home page was empty after it renamed one of its sections** – The sections an extension offers are asked for as they are now, not as they were when it was installed, so a section it renamed or added shows again.
- 🛠️ **Fixed: links an extension found through another extension's extractor failed** – The extensions that register extractors are loaded before links are fetched, whichever providers they have of their own.
- 🛠️ **Fixed: an extension's Support button did nothing when it had not been used yet** – The extension is loaded first, and its messages open.
- 🛠️ **Fixed: a repository whose plugin list held one entry that did not read was lost whole** – The repository is read now, and the entry that does not read is left out of it.
- 🛠️ **Fixed: a cs.repo link with a code in it did not add its repository** – "https://cs.repo/XXXX" is looked up as the shortcode it is, like "MegaRepo" is.
- 🛠️ **Fixed: an extension whose file was gone was still listed as installed, and a failed install left half a file behind** – The extension is forgotten, and the half-downloaded file goes, so the next install starts clean.
- 🛠️ **Fixed: switching audio or subtitles paused the video to rebuffer** – A switch now changes only the track, and the new audio plays within about a second.
- 🛠️ **Fixed: seeks in HLS streams could be lost** – A seek, or resuming where you left off, sometimes never happened. It now lands.
- 🛠️ **Fixed: some Android devices were taken for low-memory ones** – SkyStream read whether memory was short at that moment, not the device's own low-memory flag, and held such devices to a lower video quality.
- 🛠️ **Fixed: leaving or switching a stream that had stopped downloading froze the app** (iPhone, iPad, Windows and Linux) – It now leaves at once, whatever the stream is doing. On iPhone, iPad and Mac, switching away from such a stream also starts the new one at once, instead of waiting for the old one to give up.
- 🛠️ **Fixed: some streams had no Quality tab** on iPhone, iPad, Mac, Windows and Linux – Streams SkyStream relays for their headers now offer it like any other.
- 🛠️ **Fixed: on Windows, the first video after starting the app took long to open** – The player's components are now indexed once, when SkyStream is installed or first run.
- 🛠️ **Fixed: seeking in some HLS streams with subtitles took seconds longer** (iPhone, iPad, Mac, Windows and Linux) – A seek the player turns down is now sent again at once.
- 🛠️ **Fixed: on Android, the first video after installing SkyStream was slow to start** – The player now builds its list of fonts in the background as soon as SkyStream first starts, instead of when that video opens.
- 🛠️ **Fixed: on Android, video could play with sound but no picture** after the player reopened a stream.
- 🛠️ **Fixed: on Mac, a dropped connection paused the video, and a film's end paused instead of showing the end card.**
- 🛠️ **Fixed: on iPhone, iPad and Mac, switching streams quickly could crash or freeze the app.**
- 🛠️ **Fixed: after a stall, HLS streams downloaded again what had already played and came back at a lower quality** – They now pick up where they stopped, at most one segment lower.
- 🛠️ **Fixed: the "None of the sources would play" screen kept the display awake** – It now lets the screen sleep, and Retry keeps it awake again.
- 🛠️ **Fixed: on phones, a video still loading when you left the app started playing in the background.**
- 🛠️ **Fixed: the buffering spinner flickered on some streams while they played fine.**
- 🛠️ **Fixed: HDR streams were ranked above others,** though SkyStream shows HDR washed out.
- 🛠️ **Fixed: the audio and subtitle lists blinked and moved the remote's cursor while open** on some streams – The rows stay put, with the cursor where you left it.
- 🛠️ **Fixed: a page in a sign-in or bot-check sheet couldn't be scrolled on phones** – On Android and iPhone the page scrolls under your finger, and the sheet moves by its handle only. Sheets, Home's long-press menus and the source list for an external player now open above the navigation bar instead of under it.
- 🛠️ **Fixed: lines from a subtitle file flickered** – They no longer blink off and on or flash an earlier line, worst on HLS streams, and a short seek back shows the line it lands in (PR #132 by @1eren0).
- 🛠️ **Fixed: posters didn't show for some sites behind a bot check** – Once SkyStream has cleared a site's check, its posters and artwork load too.
- 🛠️ **Fixed: SubSource found no subtitles without an API key** – SubSource retired the way SkyStream searched it without a key. It is now searched the way subsource.net searches itself, with no key needed, and a key works as before.
- 🛠️ **Fixed: OpenSubtitles found no Chinese or Portuguese subtitles** – Simplified, Traditional and bilingual Chinese, and Brazil's and Portugal's Portuguese are found now, and OpenSubtitles VIP accounts use their own server.
- 🛠️ **Fixed: SubDL showed at most ten subtitles, for an episode often none of its own** – It shows thirty, the episode's own first and no other episode's. Brazil's Portuguese and bilingual Chinese are found too, hearing-impaired subtitles are marked, and choosing one no longer shows every SubDL row as downloading.
- 🛠️ **Fixed: with a SubSource API key, only the 20 newest subtitles were searched** – Every page is read now, an episode named in any of a subtitle's releases is found, and Chinese includes Traditional.
- 🛠️ **Fixed: some subtitles from Stremio add-ons showed a code instead of their language** – They show the language's name, and Traditional Chinese, Spain's Spanish and Kurdish ones are picked for a viewer who reads them.
- 🛠️ **Fixed: on TV, the remote could end up behind the player's open panel** – When playback reopened its source while the panel was open, after a quality change, a source failing over or the network coming back, the remote moved to the controls behind it.
- 🛠️ **Fixed: some repository short links and shortcodes didn't add their repository** – Links that pass through a redirect page now work, a shortcode works in any letter case ("Universe" adds SkyStream's own collection), and the add-repository boxes no longer autocorrect what you type (PR #129 by @1eren0).
- 🛠️ **Fixed: another repository could replace an extension with its own code** – An extension now updates only from the repository it was installed from, and only to the extension that repository lists. To move an extension to another repository, use Install from this repository in that repository's list.
- 🛠️ **Fixed: on TV, a keyboard closed with Back couldn't be opened again from its text field** – OK on the field opens it again, and Down moves on from the field to what is below it, in search on Home, Explore and the Search tab and in the text boxes of dialogs (PR #128 by @1eren0).
- 🛠️ **Fixed: on some low-memory Google TV devices, the on-screen keyboard showed but typed nothing into SkyStream.**
- 🛠️ **Fixed: on iPad, a video's sound stopped a second in** – The video went on playing silently until an audio track was picked again.
- 🛠️ **Fixed: leaving the player could freeze the app on iPad.**
- 🛠️ **Fixed: brightness swipes lagged on iPhone and iPad** – The brightness changed only after the finger stopped.
- 🛠️ **Fixed: on iPad and Android tablets, a tapped icon in the side navigation bar stayed enlarged** – It grew and showed its label as if a mouse were over it. The bar now grows only under a mouse, or for a remote or keyboard.
- 🛠️ **Fixed: the app could open in landscape after leaving the player.**
- 🛠️ **Fixed: on Linux, the screen stopped going to sleep after playback** until SkyStream was closed.
- 🛠️ **Fixed: on Linux, opening some streams, such as Internet Archive's, froze the app.**
- 🛠️ **Fixed: on TV, the search screen's scope selector and first result ignored the D-pad.**
- 🛠️ **Fixed: Continue Watching couldn't reopen Stremio titles** – Tapping one, or View Details on a long press, opened a plugin's page that couldn't load it. It now opens the title's own page, through the add-on it came from; a title started before this update does so once it's played again.
- 🛠️ **Fixed: Stremio shows that an add-on publishes as "other" were treated as films** – CNCVerse Bridge publishes its shows that way. Their episodes now keep their own progress and watched marks, and their page calls them a series.
- 🛠️ **Fixed: on TV, Left could jump up to the top of a page instead of into the side navigation bar** – From a button with nothing beside it, such as Select Provider on Home, Left went to the arrows at the top. It now opens the side navigation bar.
- 🛠️ **Fixed: on Windows, macOS and Linux, Clear cache could delete other apps' temporary files** – It now clears only SkyStream's own.
- 🛠️ **Fixed: the Linux .deb didn't install the VLC and WebKitGTK it needs** – apt now installs them with SkyStream.
- 🛠️ **Fixed: the Linux x64 build didn't start on Ubuntu 22.04, Debian 12 and other systems older than Ubuntu 24.04** (PR #121 by @likhithkrishna1103-tech).


### ⚙️ Improvements
- 🚀 **Linux AppImage** for x64 and arm64, beside the .deb and the archive (PR #125 by @vivin-neelankavil).
- 🚀 **For repository authors:** a SkyStream repository lists its plugins in pluginLists files; a plugins list inside the repository's own manifest is no longer read.
- 🚀 Updated to Flutter 3.47.7, Android Gradle Plugin 9.1.1 and VLC 3.0.24.
- 🚀 Fewer third-party plugins: flutter_inappwebview, screen_brightness and flutter_volume_controller are gone, replaced by SkyStream's own.
- 🚀 Thousands of new automated tests, and checks that run the app on every platform.
