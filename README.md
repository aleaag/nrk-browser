# NRK Browser (In development, expect issues)

**Browse, watch, listen to, cast and download NRK TV and NRK Radio from one Windows app.**

NRK Browser is a single PowerShell script that gives you a fast, folder-based desktop view of
[tv.nrk.no](https://tv.nrk.no) and [radio.nrk.no](https://radio.nrk.no). Watch in a built-in
video player, listen in the radio bar, cast to a Chromecast or a TV, and download whole series
with subtitles, chapters and covers, all without a browser tab.

> **Made with Claude.** NRK Browser was made with [Claude](https://claude.ai), an AI assistant
> by Anthropic. It's tested as it's built, but bugs and rough edges are to be expected. If
> something doesn't work as it should, please
> [report it](https://github.com/aleaag/nrk-browser/issues), with the log if you can
> (**Logs** > **Copy all**).

> **Unofficial.** This project is not affiliated with, endorsed by or connected to NRK
> (Norsk rikskringkasting AS). All programmes, images and trademarks belong to NRK. Downloads
> are for personal use only. Please respect NRK's terms of use and copyright, and note that
> some content is only available in Norway.

<img src="https://raw.githubusercontent.com/aleaag/nrk-browser/refs/heads/main/screenshot.png" alt="main" width="800" height="auto">

---

## Features

### Browse everything as folders
- **LIVE TV** and **LIVE Radio**: every NRK TV channel (including the regional NRK1 channels) and
  every radio channel (P1, P2, P3, mP3, Klassisk, Jazz, Nyheter, regional P1 and more), with
  today's programme guide.
- **TV Archive** and **Radio Archive**: every category on tv.nrk.no and radio.nrk.no, plus the
  complete **A–Å** indexes. Series open into seasons, seasons into episodes.
- **Favourites**: star any series or podcast (right-click › Add to favourites).
- **New this week** and **Last chance**: what came on NRK in the last 7 days, and what leaves
  within 14 days.
- **Continue watching** (what you started, and the next episode of series you watch) and
  **Watch later** (right-click › Watch later), separate from Favourites.
- **Finished watching** (what you watched or listened to to the end), a clickable breadcrumb, Back, sorting (Z–A, A–Z or NRK's order), and
  Shift/Ctrl multi-select in the tree and the list.
- **Descriptions under titles** and **"Available until"** (with "5 days left" in the list).
- **Thumbnails**: show the files list as a grid of pictures (Ctrl+G), or as a list.
- **Hidden items**: hide anything you never want to see (right-click › Hide).

### Search everything
- Press **Enter** in the search box to search every TV and radio series, programme and episode,
  from the list the indexer builds. Typing without Enter filters the folder you're in.
- **Filters** (the ▾ button next to the search box): TV / radio, series / programmes / episodes,
  only what can be watched now, and year.

### Watch: the built-in player
- NRK's stream with **subtitles** (choose the track and the text size), **chapters**, poster and
  **speed** (0.75×–2×).
- **Live TV** with **Start over** (the programme on now, from its beginning), **−1 min** and
  **LIVE**: NRK keeps about 3 hours.
- **Audio description** (synstolking) and other sound tracks, and other versions NRK lists
  (sign language), under **Audio ▾**.
- **Continues where you stopped**, to the second, also after a restart, crash or update.
  Watched episodes get a green line in the list; started ones show how far you got.
- Previous/next episode, autoplay with a **countdown card** (Play now / Cancel), full screen, keep on
  top, a **mini player** that stays on top, **picture quality** choice and **screenshots**.
- Subtitle **colour, background and position**.
- "Open NRK page" plays a programme in NRK's own web player instead.

### Listen: the radio bar
- Radio programmes, podcasts and live radio in a bar at the bottom of the window.
- Play/pause, ±15 s, seek, speed, volume; seek back through live radio and jump to live.
- **Your own queue**: right-click › Play next / Add to queue.
- **Skip silences** and **voice boost**; per series or podcast: its own **speed**, and **skip the
  intro / the outro** (the bars button in the radio bar).
- Live radio shows the **song playing now**; a **small radio window** stays on top.
- **Wake to radio**: a channel at a set time on the days you pick (Options › Wake to radio).
- **Sleep timer** (the moon button, the player window or the tray): 15–120 minutes or the end of
  this episode; the volume goes down over the last minute.
- Media keys and Windows' media controls work.

### Cast to a Chromecast or a TV
- **Cast ▾** (main window and player window) finds Chromecasts and TVs (DLNA) on your network.
- A Chromecast plays NRK's stream itself, with subtitles; a TV gets the stream remuxed by FFmpeg
  on your PC (TVs rarely play NRK's own format).
- The cast bar: ±30 s, play/pause, seek, subtitles, mute, volume, Stop casting. It continues
  where you stopped, plays the next episode, and casts again after a restart.
- The first time, Windows asks whether PowerShell may use the network: allow it on private
  networks, or subtitles (Chromecast) and TVs won't work.

### Record
- **Record live TV and radio**: right-click a live channel › Record… (now, or from a time), or a
  programme in the TV schedule › Record this programme. FFmpeg copies NRK's stream as it is.

### Download
- Every Download adds to a **queue**: whole seasons, series, categories or selected files.
- **TV**: MP4 (or MKV) in NRK's best quality (or up to 1080p / 720p / 480p / 360p), copied as it
  is, with **subtitles inside the file** (and as .srt), **chapters**, **cover** and tags.
- **Radio**: as NRK sends it (M4A/AAC or MP3), or converted to MP3 (320 kbps) or FLAC, with tags
  and cover.
- **Pause / resume**, also after a restart; a lost connection pauses and continues by itself;
  damaged pieces are fetched again.
- **Follow a series**: new episodes download by themselves (right-click a favourite › Follow), or
  just get a notification (Follow, only tell me).
- **File names** of your own: `{series} - S{season}E{episode} - {title}` (Options › Download rules).
- **Download history**: what you downloaded before isn't fetched again, even after you moved or
  deleted it ("Download again" when you want it).
- **Kodi / Jellyfin / Plex**: .nfo files, posters and fanart next to the videos.
- Whole series: only the newest N episodes, or only those after a date.
- Speed limit, download hours (for example 01:00–07:00), a disk space check, and a Windows
  notification when the queue is done (**Options › Download rules**).
- Update the tags and cover of files you already have; delete downloaded files; open their folder.
- Podcasts: copy NRK's own podcast feed (RSS) address for your podcast app, or export all your
  favourite podcasts as OPML.

### Fits into Windows
- Light and dark theme (follows Windows), and 11 looks for the icons in the top bar and on the
  buttons of every window (Options › General › Icon style).
- System tray: minimize or close to the tray and keep playing; Pause, Mute, Sleep timer,
  Check for updates, Exit.
- Start with Windows, one copy at a time, sound output for this app only.
- **Global hotkeys** (also in the background) and shortcuts you can change (Options › Shortcuts).
- **Taskbar**: Previous / Play / Next under the preview, recent channels when you right-click it.
- **Phone remote**: control playback from a phone on your home network (Options › Phone remote).
- **Statistics**: hours watched and listened to, and your most played series.
- **Child mode** (with a PIN): only NRK Super and children's categories, nothing rated above the
  age you choose, no search.
- **Find setting** box at the top of Options.
- **Back up and restore** your settings, favourites, hidden items, watched list and download list.

### Install, update and repair
- Runs from anywhere, or installs itself to `%LOCALAPPDATA%\NRK-Browser` with shortcuts.
- Built-in updater: checks this repository and replaces itself (keeps a backup).
- Components window: checks everything the app needs and installs what's missing, with your
  permission. Never needs administrator rights.
- An **indexer** saves every folder in the background (daily, or by itself when the saved data is
  old), so folders open instantly and search covers everything. It sends several requests at once
  and slows down by itself when NRK answers slowly or asks it to. Series you open or search for
  go first, then your favourites and what you played lately. Most runs are a quick check: series
  that have been quiet lately are looked at less often, and only the seasons where something can
  have changed are read again. A full check runs every 30 days, or with **Check everything**.
  Search finds every series name a few minutes into a run, and the newest seasons of every series
  come before the older ones. While it runs, the window title shows how far it is and the time
  left, and a thin bar fills under the Indexer button. Pages that haven't changed aren't written
  to disk again.

---

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (built in) or PowerShell 7+
- .NET Framework 4.7.2 or later (part of Windows 10 1803 and newer)

Everything else is checked at startup and installed on request:

| Component | Used for | Installed via |
|---|---|---|
| Microsoft Edge WebView2 Runtime | the video player and the radio bar (normally part of Windows) | winget |
| WebView2 SDK for .NET | lets PowerShell host WebView2 | nuget.org |
| hls.js | NRK's streams in the player and the radio bar | jsDelivr |
| FFmpeg | downloads, recordings, and casting to a TV | winget (`Gyan.FFmpeg`) |
| winget | installing the above (only if needed) | App Installer |

## Getting started

1. Download **`NRK-Browser.ps1`** from this repository.
2. Right-click it and choose **Run with PowerShell**, or run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\NRK-Browser.ps1
   ```
3. On first start, the components window lists anything missing. Tick what to install and press
   **Install selected**.
4. Optional: **Options › Install & files › Install** copies it to `%LOCALAPPDATA%\NRK-Browser`
   and adds shortcuts.

## Using it

| Do this | How |
|---|---|
| Watch or listen | select a file and press **Play / Listen**, or double-click |
| Cast | **Cast ▾** next to Download, or in the player window |
| Download | **Download**, or right-click files or folders › **Download**, then **Download selected** in the Downloads window |
| Search everything | type in the search box and press **Enter** |
| Select several | Shift+click or Ctrl+click (files and folders) |
| Go back | the **‹** button, Backspace, or click a folder in the path at the top |

**Keyboard shortcuts**

| Key | Action |
|---|---|
| `Ctrl+,` | Options |
| `Ctrl+L` | Logs |
| `Ctrl+D` | Downloads |
| `Ctrl+I` | Indexer |
| `Ctrl+F` | Filter / search box |
| `Ctrl+G` | Files as thumbnails / as a list |
| `Ctrl+W` | Watch later (selected files) |
| `Ctrl+R` | Recordings |
| `Ctrl+Alt+P`, `Ctrl+Alt+Shift+←/→`, `Ctrl+Alt+Shift+↑/↓`, `Ctrl+Alt+M`, `Ctrl+Alt+N` | Anywhere in Windows: play/pause, previous/next, volume, mute, show the app |
| `F11` / `Esc` | Player full screen / leave full screen |
| `Space`, `←` / `→` | Player and radio bar: play/pause, back/forward |
| `Ctrl+↑` / `Ctrl+↓`, `Del` | Downloads: move or remove the selected files |

**Command-line options**

| Option | Effect |
|---|---|
| `-Tray` | start hidden in the system tray (used by "Start with Windows") |
| `-Index` | no window: run the indexer (a quick check, or a full one when the last is 30 days old) |
| `-Index -IndexFull` | no window: run the indexer and check every season of every series |
| `-SelfTest` | no window: call each NRK endpoint once, print a summary and write the log |
| `-DumpResponses` | also save every raw NRK API response to the log folder |
| `-LogDir <folder>` | write logs somewhere else |
| `-ShowConsole` | keep the PowerShell console visible |
| `-Play radio:p1` / `-Play tv:nrk1` | start that channel (used by the taskbar jump list) |

## Where things are stored

Everything lives in **`%LOCALAPPDATA%\NRK-Browser`** (Options › Install & files › View local files):

| Path | Contents |
|---|---|
| `settings.json` | your options |
| `favourites.json`, `excluded.json`, `finished.json` | favourites (and followed series), hidden items, Finished watching |
| `positions.json` | where you stopped in each programme, and what you've watched |
| `continue.json`, `watchlater.json` | Continue watching and Watch later |
| `seriesprefs.json`, `recentchannels.json` | speed and skips per series; channels for the jump list and phone remote |
| `recordings.json`, `stats.json` | planned and done recordings; statistics |
| `downloads.json`, `dlhistory.json` | the download list, and what was downloaded before |
| `indexer\` | the indexer's list of everything (search, New this week, Last chance) |
| `cache\` | saved NRK pages and images (clear it in Options) |
| `assets\` | icons and folder pictures, unpacked from this repository's `assets.zip` (fetched again only when it changes) |
| `logs\` | log files, when **Save logs to disk** is on |
| `backups\` | what you had before a restore |
| `webview2-sdk\`, `hls.js\`, `WebView2Data\` | components and player data |

Downloads go to **Videos\NRK-Browser** (TV) and **Music\NRK-Browser** (radio), or the folders you
choose in **Options › Downloads**.

## Troubleshooting

- **Nothing loads**: run with `-SelfTest`, then look at **Logs** (`Ctrl+L`). **Pause** there stops
  the view from scrolling while you read; the app keeps logging.
- **Search, New this week or Last chance is empty**: they come from the indexer; open it
  (`Ctrl+I`) and let the first run get through the folders (series names are searchable after a few
  minutes; their episodes follow).
- **A programme plays on NRK's page instead of the built-in player**: it's copy-protected, so only
  NRK's own player can play it.
- **Casting finds nothing / a TV shows an error**: the PC and the device must be on the same
  network, and Windows must allow PowerShell on it (Windows Defender Firewall › Allowed apps).
- **A component is broken**: **Options › Updates › Components… › Reinstall**.
- **Not available outside Norway**: some NRK content is geo-blocked; the app shows NRK's reason.

## Releasing a new version (maintainers)

1. Raise `$script:AppVersion` near the top of `NRK-Browser.ps1`.
2. Commit `NRK-Browser.ps1` to the root of `main`.
3. Running copies download that file, compare its version line with their own, and install it
   when it is newer.
4. Changed or new icons/pictures: they are all in **`assets.zip`**, and **`assets.json`** gives its
   SHA-256. Commit both to the root of `main`. Running copies fetch the zip again only when that
   hash changes, and only use it when the hash matches.

## Credits

- Made with [Claude](https://claude.ai), an AI assistant by Anthropic.
- Programme data, images and streams: **NRK** (psapi.nrk.no).
- [hls.js](https://github.com/video-dev/hls.js) (Apache-2.0): HLS playback.
- [FFmpeg](https://ffmpeg.org): downloads and casting to TVs.
- [Microsoft Edge WebView2](https://developer.microsoft.com/microsoft-edge/webview2/): embedded browser engine.
- API research helped by [nrk-psapi](https://github.com/bendikrb/nrk-psapi) and
  [nrk-pod-feeds](https://github.com/sindrel/nrk-pod-feeds).
