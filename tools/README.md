# cdj400-* tools

These are the command-line tools that do the real work. The app is a front-end that runs them. Every tool also works on its own. The Python tools take `--help`, and the shell tools print their usage when run without arguments.

Tools that change a stick do a dry run by default. They only make changes when given `--execute`.

| Tool | What it does | Used by the app for |
| --- | --- | --- |
| `cdj400-dbexport` | Writes a Rekordbox-format XML from the live library database (`master.db`). It works on a copy, so it's safe while Rekordbox is running. `--device` scopes the export to the playlists synced to one stick. | Dry Run, Make Lean |
| `cdj400-adopt` | Rebuilds `Playlists/` from the audio already on a Rekordbox-exported stick. It renames files within the stick, so it doesn't copy from the Mac. First it backs up `PIONEER/`, plus any `Contents/` files no playlist uses, to the Mac and records where every file went. Then it strips `PIONEER/` and `Contents/`. `--tidy-names` names files `Artist - Title.mp3`. | Dry Run, Make Lean |
| `cdj400-restore` | Puts a lean stick back in Rekordbox mode. It uses the backup Make Lean made, which `Playlists/.cdj400-lean.json` names, and checks the volume UUID. Files move back into `Contents/` without copying, then `Playlists/` is removed. It refuses an older backup or one from another stick. | Restore to Rekordbox |
| `cdj400-backups` | `--list` shows every restore backup with its size and status: needed by a plugged-in stick, the newest for a stick that isn't plugged in, older, not needed, or incomplete. `--delete` removes backups, but never one a plugged-in stick restores from. | Restore Backups window |
| `cdj400-rename` | `--tidy` renames a lean stick's files `Artist - Title` from Rekordbox's metadata. `--original` puts the Mac names back. Sort order is kept. | File Names |
| `cdj400-addplaylist` | `--list` shows library playlists not yet on the stick. Given a playlist name, it copies that playlist's MP3s into `Playlists/<name>/`. `--status` compares every folder with the library. `--prune` deletes tracks that left the playlist. Renamed and sorted tracks are matched by their Mac name, and new tracks follow the folder's naming. | Add Playlist, Check / Update |
| `cdj400-sort` | Orders a folder's tracks by BPM, key (Camelot) or name, using Rekordbox's analysis. Tidy names are kept. | Sort |
| `cdj400-copystick` | Copies a lean stick's `Playlists/` onto another stick. It only adds files and never deletes any. | Copy to… |
| `cdj400-usb` | One-shot finishing pass after a Rekordbox sync. It runs `cdj400-finalize.py` on every plugged-in stick, or on just the mount points listed in `$CDJ400_STICKS`. | (command line only) |
| `cdj400-finalize.py` | Builds `Playlists/` from a Rekordbox XML export. With `--lean`, it backs up `PIONEER/` and `Contents/` first and then strips them. | (command line only) |
| `cdj400-prestrip` | Backs up and removes `PIONEER/` and `Contents/` to free space on a stick that's too full for a lean render. | (command line only) |

The tools find each other by their own folder, so keep them together. `cdj400_names.py` holds the naming rules they share.

## File names

On a lean stick, each playlist folder can hold a `.cdj400-order.json`. It records whether the folder uses `Artist - Title` names, how it's sorted, which files have a `001 - ` sort prefix, and the Mac name of every renamed file. The tools match tracks by those Mac names, so renaming or sorting never makes Check / Update copy a track again or prune it.

The tidy name is `Artist - Title.mp3`, taken from Rekordbox's artist and title. With no artist it's just the title, and with no title the original name is kept. Mix names like "(Original Mix)" stay. Characters FAT32 can't store are replaced (`/` and `:` become dashes), names stop at 100 characters, and a name two tracks would share gets ` (2)`.

## Tests

```bash
python3 -m unittest discover -s Tests/tools -v
```

These run every tool against a fake stick and library in a temporary home folder. `swift test` runs them too.

## Requirements

- `python3` 3.9 or later. The Xcode Command Line Tools provide one.
- [pyrekordbox](https://github.com/dylanljones/pyrekordbox), needed by `cdj400-dbexport` and so by every tool that exports from the library. It is expected in a virtualenv at `~/venvs/rekordbox`. `cdj400-dbexport` re-executes itself under that interpreter.

  ```bash
  python3 -m venv ~/venvs/rekordbox
  ~/venvs/rekordbox/bin/pip install pyrekordbox
  ```

- Rekordbox installed, with its library at `~/Library/Pioneer/rekordbox/master.db`.
- `rsync`, `mdutil`, `dot_clean` and `diskutil`. All of these ship with macOS.

## Files the tools write

| Location | Contents |
| --- | --- |
| `~/Music/DJ.CDJ400-BACKUPS/<stick>-<stamp>/` | Backups that `cdj400-restore` reads. Make Lean's hold `PIONEER/`, the unused `Contents/` files and `restore-map.json`. Older ones from `cdj400-finalize.py --lean` and `cdj400-prestrip` hold all of `PIONEER/` and `Contents/`. Make Lean keeps only the newest for each stick. |
| `~/Music/DJ.USB-DEVICEDBS/<stick>-<date>/` | A copy of each stick's Rekordbox device database, kept before stripping |
| `$TMPDIR/cdj400/` | Scratch copies of the library database and XML exports |

## Environment

| Variable | Effect |
| --- | --- |
| `CDJ400_FORCE=1` | Skips the "this stick was written in the last 90 seconds" safety check (already skipped when Rekordbox is closed) |
| `CDJ400_STICKS` | Space-separated mount points for `cdj400-usb` to finish, instead of every plugged-in stick |
