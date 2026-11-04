# cdj400-* tools

These are the command-line tools that do the real work. The app is a front-end that runs them. Every tool also works on its own. The Python tools take `--help`, and the shell tools print their usage when run without arguments.

Tools that change a stick do a dry run by default. They only make changes when given `--execute`.

| Tool | What it does | Used by the app for |
| --- | --- | --- |
| `cdj400-dbexport` | Writes a Rekordbox-format XML from the live library database (`master.db`). It works on a copy, so it's safe while Rekordbox is running. `--device` scopes the export to the playlists synced to one stick. | Dry Run, Make Lean |
| `cdj400-adopt` | Rebuilds `Playlists/` from the audio already on a Rekordbox-exported stick. It renames files within the stick, so it doesn't copy from the Mac. Then it strips `PIONEER/` and `Contents/`. | Dry Run, Make Lean |
| `cdj400-restore` | Puts `PIONEER/` and `Contents/` back from the newest backup. | Restore to Rekordbox |
| `cdj400-addplaylist` | `--list` shows library playlists not yet on the stick. Given a playlist name, it copies that playlist's MP3s into `Playlists/<name>/`. `--status` compares every folder with the library. `--prune` deletes tracks that left the playlist. | Add Playlist, Check / Update |
| `cdj400-sort` | Orders a folder's tracks by BPM, key (Camelot) or name, using Rekordbox's analysis. | Sort |
| `cdj400-copystick` | Copies a lean stick's `Playlists/` onto another stick. It only adds files and never deletes any. | Copy to… |
| `cdj400-usb` | One-shot finishing pass after a Rekordbox sync. It runs `cdj400-finalize.py` on every plugged-in stick, or on just the mount points listed in `$CDJ400_STICKS`. | (command line only) |
| `cdj400-finalize.py` | Builds `Playlists/` from a Rekordbox XML export. With `--lean`, it backs up `PIONEER/` and `Contents/` first and then strips them. | (command line only) |
| `cdj400-prestrip` | Backs up and removes `PIONEER/` and `Contents/` to free space on a stick that's too full for a lean render. | (command line only) |

The tools find each other by their own folder, so keep them together.

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
| `~/Music/DJ.CDJ400-BACKUPS/<stick>-<stamp>/` | `PIONEER/` and `Contents/` backups that `cdj400-restore` reads |
| `~/Music/DJ.USB-DEVICEDBS/<stick>-<date>/` | A copy of each stick's Rekordbox device database, kept before stripping |
| `$TMPDIR/cdj400/` | Scratch copies of the library database and XML exports |

## Environment

| Variable | Effect |
| --- | --- |
| `CDJ400_FORCE=1` | Skips the "this stick was written in the last 90 seconds" safety check |
| `CDJ400_STICKS` | Space-separated mount points for `cdj400-usb` to finish, instead of every plugged-in stick |
