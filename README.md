# CDJ-400 Sticks

A small macOS app for managing USB sticks for Pioneer CDJ-400 decks.

The CDJ-400 predates Rekordbox's current export format and browses a stick far faster when the music is in plain folders. This app shows every Rekordbox stick you plug in, flags what will trip up the deck, and can rebuild a stick into a **lean** layout: one `Playlists/<name>/` folder of MP3s per playlist, with Rekordbox's `PIONEER/` and `Contents/` folders removed.

The app is a front-end. The actual copying, exporting and sorting is done by the `cdj400-*` command-line tools in [`tools/`](tools/README.md). The app runs them and streams their output into its window. The tools also work on their own.

## Features

- **Stick list** in the window sidebar and in the menu bar. It refreshes automatically when a volume mounts or unmounts. Each stick shows its mode, free space, and a warning when something other than this app wrote to it in the last 90 seconds, which usually means Rekordbox is still syncing.
- **Health checks** with one-click fixes where possible:
  - `._` sidecar files. Fix: remove them.
  - Spotlight indexing the stick. Fix: turn it off. This asks for your password.
  - Non-MP3 audio the deck can't play.
  - Less than 10% free space.
  - A file system other than FAT32.
- **Dry Run / Make Lean.** Exports the stick's own playlist manifest from Rekordbox. Dry Run previews the lean rebuild. Make Lean rebuilds `Playlists/`, then strips `PIONEER/` and `Contents/` once every file verifies.
- **Restore to Rekordbox.** Returns a lean stick to Rekordbox mode.
- **Playlists on a lean stick.** Search playlists and track names. Add playlists straight from the Rekordbox library, with a check that they will fit. Sort tracks by BPM, key (Camelot) or name. Remove a playlist. Check every folder against Rekordbox and update only the ones that changed.
- **Copy to…** copies all of a lean stick's playlists onto another lean stick.
- **Output pane** with live progress (percent, MB/s, time left), a Stop button, and the logs of the last 25 runs. A notification is posted when a job finishes.

| Shortcut | Action |
| --- | --- |
| ⌘R | Refresh sticks |
| ⌘D | Dry Run |
| ⇧⌘L | Make Lean |
| ⌘E | Eject |
| ⌘⎋ | Stop the running job |
| ⇧⌘K | Clear the output |

## Requirements

- macOS 26 or later, and Xcode 26 (Swift 6.2 or newer) to build.
- Rekordbox, plus [pyrekordbox](https://github.com/dylanljones/pyrekordbox) in a virtualenv at `~/venvs/rekordbox`. The tools read the live Rekordbox library through it:

  ```bash
  python3 -m venv ~/venvs/rekordbox
  ~/venvs/rekordbox/bin/pip install pyrekordbox
  ```

The `cdj400-*` tools the app runs live in [`tools/`](tools/README.md), and `build.sh` bundles them into the app. Jobs run through a login `zsh` (`zsh -lc`), so your normal `PATH` applies. Tools that print `PROGRESS <bytes done> <bytes total>` lines drive the progress bar.

## Build and run

```bash
./build.sh
```

This builds a release binary and installs `CDJ-400 Sticks.app` into `~/Applications`. To put it somewhere else, pass a folder: `./build.sh /Applications`.

For development:

```bash
swift build
swift test
CDJ_DEMO=1 swift run
```

`CDJ_DEMO=1` replaces the real `/Volumes` scan with three sample sticks, so you can work on the UI without hardware. A bare `swift run` binary has no bundle identifier, so it skips notifications. Use `build.sh` to get those.

The app looks for the tools in `$CDJ400_TOOLS`, then in its own bundle, then in `~/bin`. A bare `swift run` binary has no bundle, so point it at the repo's copy with `CDJ400_TOOLS="$PWD/tools" swift run`.

## Project layout

```
Sources/CDJ400UI/
  CDJ400UIApp.swift     App entry point: main window and menu bar extra
  AppModel.swift        Shared state: sticks, selection, sync checks, the job runner
  Stick.swift           Domain types: Stick, Playlist, StickIssue, PlaylistSync, StickAction
  StickScanner.swift    Reads /Volumes: mode, playlists, capacity, health
  StickCommands.swift   Every shell command the app runs, plus Job (what can run on a stick)
  CommandRunner.swift   Runs one job at a time, streams output, keeps run history
  Shell.swift           Short read-only commands; the Application Support folder
  ContentView.swift     Window layout and sidebar
  StickDetailView.swift The selected stick
  AddPlaylistSheet.swift
  LogView.swift         Output pane
  Theme.swift           Colors and shared view components
Tests/CDJ400UITests/    Parsing, shell quoting, output streaming and tool smoke tests
tools/                  The cdj400-* command-line tools (see tools/README.md)
icon/                   App icon source (make-icon.swift) and the built AppIcon.icns
```

App data (run history and the per-stick XML exports) lives in `~/Library/Application Support/CDJ400UI/`.

## Regenerating the icon

The icon is drawn in code. To rebuild `icon/AppIcon.icns`:

```bash
cd icon
swift make-icon.swift icon-1024.png
mkdir -p AppIcon.iconset
for size in 16 32 128 256 512; do
  sips -z $size $size icon-1024.png --out AppIcon.iconset/icon_${size}x${size}.png
  sips -z $((size * 2)) $((size * 2)) icon-1024.png --out AppIcon.iconset/icon_${size}x${size}@2x.png
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

## License

MIT. See [LICENSE](LICENSE).
