# NRK Browser (In development, expect issues)

**Browse, watch, listen to, cast and download NRK TV and NRK Radio from one Windows app.**

NRK Browser is a single PowerShell script that gives you a fast, folder-based desktop view of
[tv.nrk.no](https://tv.nrk.no) and [radio.nrk.no](https://radio.nrk.no). Watch in a built-in
video player, listen in the radio bar, cast to a Chromecast or a TV, and download whole series
with subtitles, chapters and covers, all without a browser tab.

> **Unofficial.** This project is not affiliated with, endorsed by or connected to NRK
> (Norsk rikskringkasting AS). All programmes, images and trademarks belong to NRK. Downloads
> are for personal use only. Please respect NRK's terms of use and copyright, and note that
> some content is only available in Norway.

<img src="https://raw.githubusercontent.com/aleaag/nrk-browser/refs/heads/main/main.png" alt="main" width="800" height="auto">

<img src="https://raw.githubusercontent.com/aleaag/nrk-browser/refs/heads/main/main.png" alt="main" width="800" height="auto">

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
- **Recently played**, a clickable breadcrumb, Back, sorting (Z–A, A–Z or NRK's order), and
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
- Previous/next episode, autoplay of the next one (can be turned off), full screen, keep on top.
- "Open NRK page" plays a programme in NRK's own web player instead.

### Listen: the radio bar
- Radio programmes, podcasts and live radio in a bar at the bottom of the window.
- Play/pause, ±15 s, seek, speed, volume; seek back through live radio and jump to live.
- **Your own queue**: right-click › Play next / Add to queue.
- **Sleep timer** (the moon button, the player window or the tray): 15–120 minutes or the end of
  this episode.
- Media keys and Windows' media controls work.

### Cast to a Chromecast or a TV
- **Cast ▾** (main window and player window) finds Chromecasts and TVs (DLNA) on your network.
- A Chromecast plays NRK's stream itself, with subtitles; a TV gets the stream remuxed by FFmpeg
  on your PC (TVs rarely play NRK's own format).
- The cast bar: ±30 s, play/pause, seek, subtitles, mute, volume, Stop casting. It continues
  where you stopped, plays the next episode, and casts again after a restart.
- The first time, Windows asks whether PowerShell may use the network: allow it on private
  networks, or subtitles (Chromecast) and TVs won't work.

### Download
- Every Download adds to a **queue**: whole seasons, series, categories or selected files.
- **TV**: MP4 (or MKV) in NRK's best quality (or up to 1080p / 720p / 480p / 360p), copied as it
  is, with **subtitles inside the file** (and as .srt), **chapters**, **cover** and tags.
- **Radio**: as NRK sends it (M4A/AAC or MP3), or converted to MP3 (320 kbps) or FLAC, with tags
  and cover.
- **Pause / resume**, also after a restart; a lost connection pauses and continues by itself;
  damaged pieces are fetched again.
- **Follow a series**: new episodes download by themselves (right-click a favourite › Follow).
- **Download history**: what you downloaded before isn't fetched again, even after you moved or
  deleted it ("Download again" when you want it).
- **Kodi / Jellyfin / Plex**: .nfo files, posters and fanart next to the videos.
- Whole series: only the newest N episodes, or only those after a date.
- Speed limit, download hours (for example 01:00–07:00), a disk space check, and a Windows
  notification when the queue is done.
- Update the tags and cover of files you already have; delete downloaded files; open their folder.
- Podcasts: copy NRK's own podcast feed (RSS) address for your podcast app.

### Fits into Windows
- Light and dark theme (follows Windows), 11 looks for the top-bar icons.
- System tray: minimize or close to the tray and keep playing; Pause, Mute, Sleep timer,
  Check for updates, Exit.
- Start with Windows, one copy at a time, sound output for this app only.
- **Child mode** (with a PIN): only NRK Super and children's categories, nothing rated above the
  age you choose, no search.
- **Back up and restore** your settings, favourites, hidden items, watched list and download list.

### Install, update and repair
- Runs from anywhere, or installs itself to `%LOCALAPPDATA%\NRK-Browser` with shortcuts.
- Built-in updater: checks this repository and replaces itself (keeps a backup).
- Components window: checks everything the app needs and installs what's missing, with your
  permission. Never needs administrator rights.
- An **indexer** saves every folder in the background (daily, or by itself when the saved data is
  old), so folders open instantly and search covers everything.

---

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (built in) or PowerShell 7+

Everything else is checked at startup and installed on request:

| Component | Used for | Installed via |
|---|---|---|
| Microsoft Edge WebView2 Runtime | the video player and the radio bar (normally part of Windows) | winget |
| WebView2 SDK for .NET | lets PowerShell host WebView2 | nuget.org |
| hls.js | NRK's streams in the player and the radio bar | jsDelivr |
| FFmpeg | downloads, and casting to a TV | winget (`Gyan.FFmpeg`) |
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
| `F11` / `Esc` | Player full screen / leave full screen |
| `Space`, `←` / `→` | Player and radio bar: play/pause, back/forward |
| `Ctrl+↑` / `Ctrl+↓`, `Del` | Downloads: move or remove the selected files |

**Command-line options**

| Option | Effect |
|---|---|
| `-Tray` | start hidden in the system tray (used by "Start with Windows") |
| `-Index` | no window: run the indexer |
| `-SelfTest` | no window: call each NRK endpoint once, print a summary and write the log |
| `-DumpResponses` | also save every raw NRK API response to the log folder |
| `-LogDir <folder>` | write logs somewhere else |
| `-ShowConsole` | keep the PowerShell console visible |

## Where things are stored

Everything lives in **`%LOCALAPPDATA%\NRK-Browser`** (Options › Install & files › View local files):

| Path | Contents |
|---|---|
| `settings.json` | your options |
| `favourites.json`, `excluded.json`, `recent.json` | favourites (and followed series), hidden items, recently played |
| `positions.json` | where you stopped in each programme, and what you've watched |
| `downloads.json`, `dlhistory.json` | the download list, and what was downloaded before |
| `indexer\` | the indexer's list of everything (search, New this week, Last chance) |
| `cache\` | saved NRK pages and images (clear it in Options) |
| `images\` | the NRK TV picture used for TV folders without one |
| `logs\` | log files, when **Save logs to disk** is on |
| `backups\` | what you had before a restore |
| `webview2-sdk\`, `hls.js\`, `WebView2Data\` | components and player data |

Downloads go to **Videos\NRK-Browser** (TV) and **Music\NRK-Browser** (radio), or the folders you
choose in **Options › Downloads**.

## Troubleshooting

- **Nothing loads**: run with `-SelfTest`, then look at **Logs** (`Ctrl+L`).
- **Search, New this week or Last chance is empty**: they come from the indexer; open it
  (`Ctrl+I`) and let a full run finish.
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
   when it is newer. There is nothing else to publish.

## Credits

- Programme data, images and streams: **NRK** (psapi.nrk.no).
- [hls.js](https://github.com/video-dev/hls.js) (Apache-2.0): HLS playback.
- [FFmpeg](https://ffmpeg.org): downloads and casting to TVs.
- [Microsoft Edge WebView2](https://developer.microsoft.com/microsoft-edge/webview2/): embedded browser engine.
- API research helped by [nrk-psapi](https://github.com/bendikrb/nrk-psapi) and
  [nrk-pod-feeds](https://github.com/sindrel/nrk-pod-feeds).
