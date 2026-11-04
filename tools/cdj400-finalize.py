#!/usr/bin/env python3
"""cdj400-finalize: make a Rekordbox-synced FAT32 USB legible to pre-Rekordbox players (CDJ-400 era).

Usage:
    cdj400-finalize.py <rekordbox.xml> <usb-mount> [--only PlaylistA,PlaylistB] [--skip-over N]

What it does (and only this):
  1. Sanity-checks the USB is FAT32 + MBR (warns, never reformats).
  2. Builds <usb>/Playlists/<playlist>/ from the XML (MP3 only, depth 2).
  3. Purges macOS AppleDouble sidecars + Spotlight/Trashes junk, disables Spotlight.
  4. ffprobe-audits every copied MP3 (CDJ-400: <=48kHz) and verifies counts vs manifest.
  5. Writes a build manifest to <usb>/Playlists/.build-manifest.json (dotfile: players ignore it).

Never touches Contents/ or PIONEER/ — modern Rekordbox use is unaffected —
UNLESS --lean is passed, which backs them up (default) and strips them so
pre-Rekordbox players (CDJ-400 era) read the stick fast: those decks pre-read
the entire directory structure at insert, so file count is everything.
Modern players fall back to folder browsing without the DB; restore from the
backup or a Rekordbox re-sync when the full rekordbox experience is needed.
Re-runnable: Playlists/ is a build artifact, wiped and regenerated each run.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

FAT32_BAD = '<>:"/\\|?*'
MAX_BASENAME = 100  # chars, keeps CDJ displays usable


def fat32_safe(name: str) -> str:
    name = "".join(c for c in name if c not in FAT32_BAD).strip().rstrip(".")
    if len(name) > MAX_BASENAME:
        stem, dot, ext = name.rpartition(".")
        stem = stem[: MAX_BASENAME - len(ext) - 1] if dot else name[:MAX_BASENAME]
        name = f"{stem}.{ext}" if dot else stem
    return name or "untitled"


def url_to_path(url: str) -> Path | None:
    if not url.startswith("file://"):
        return None
    return Path(urllib.request.url2pathname(urllib.parse.urlparse(url).path))


def parse_xml(xml_path: Path):
    """Returns (tracks: {TrackID: {location, kind}}, playlists: [(name, [TrackID])])."""
    tracks, playlists = {}, []
    # iterparse over the whole file: playlist TRACK nodes are Key-only refs,
    # collection TRACK nodes carry Location. Counting all TRACK nodes at once
    # double-counts, so separate by context.
    for event, elem in ET.iterparse(xml_path, events=("end",)):
        if elem.tag == "TRACK" and elem.get("Location"):
            tracks[elem.get("TrackID")] = {
                "location": url_to_path(elem.get("Location")),
                "kind": elem.get("Kind", ""),
            }
            elem.clear()
        elif elem.tag == "NODE" and elem.get("Type") == "1":  # playlist node
            name = elem.get("Name", "Unnamed")
            keys = [t.get("Key") for t in elem.iter("TRACK") if t.get("Key")]
            playlists.append((name, keys))
            elem.clear()
    return tracks, playlists


def check_volume(usb: Path):
    out = subprocess.run(["mount"], capture_output=True, text=True).stdout
    line = next((l for l in out.splitlines() if f" on {usb} " in l), "")
    fstype = f"({'msdos' in line})"
    print(f"mount: {line or 'NOT A MOUNT POINT?!'}")
    if "msdos" not in line:
        print("WARN: not FAT32 — CDJ-400 cannot read this stick. Aborting.")
        sys.exit(2)
    whole = subprocess.run(
        ["diskutil", "info", usb], capture_output=True, text=True
    ).stdout
    if "FDisk_partition_scheme" not in whole and "GUID" in whole:
        print("WARN: not MBR partition map — CDJ-400 may refuse it. Aborting.")
        sys.exit(2)
    print("volume OK: FAT32 + MBR")


def purge_apple_junk(usb: Path):
    subprocess.run(["dot_clean", str(usb)], check=False)
    # dot_clean merges most sidecars but can leave stragglers; sweep them.
    for p in usb.rglob("._*"):
        try:
            p.unlink()
        except OSError:
            pass
    for junk in (".Spotlight-V100", ".fseventsd", ".Trashes",
                 "System Volume Information"):
        shutil.rmtree(usb / junk, ignore_errors=True)
    subprocess.run(["mdutil", "-i", "off", str(usb)],
                   capture_output=True, check=False)
    leftovers = sum(1 for _ in usb.rglob("._*"))
    print(f"apple junk purged, ._* remaining: {leftovers}")


def audit_mp3(path: Path):
    """Returns (sample_rate, ok). Header probe only — fast."""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "a:0",
             "-show_entries", "stream=sample_rate", "-of", "csv=p=0", str(path)],
            capture_output=True, text=True, timeout=30).stdout.strip()
        rate = int(out.split(",")[0])
        return rate, rate <= 48000
    except Exception:
        return 0, False


def forced() -> bool:
    return subprocess.run(["printenv", "CDJ400_FORCE"], capture_output=True,
                          text=True).stdout.strip() == "1"


def recent_write(usb: Path, secs: int = 90):
    """First file written to the stick within `secs`, else None. A hit means
    Rekordbox is very likely mid-export — never mutate the stick then."""
    cutoff = time.time() - secs
    for part in ("PIONEER", "Contents"):
        d = usb / part
        if not d.exists():
            continue
        for p in d.rglob("*"):
            try:
                if p.is_file() and p.stat().st_mtime > cutoff:
                    return p
            except OSError:
                continue
    return None


def prune_older_backups(stick: str, keep: Path) -> None:
    """One backup per stick is enough — cdj400-restore only ever reads the
    newest, so anything older is dead weight on the laptop. Never drop an older
    backup holding a part this one lacks (e.g. a stick with no PIONEER/)."""
    if not keep.exists():
        return
    for old in sorted(keep.parent.glob(f"{stick}-*")):
        if old == keep or not old.is_dir():
            continue
        if any((old / p).is_dir() and not (keep / p).is_dir()
               for p in ("PIONEER", "Contents")):
            print(f"  keeping older backup (has parts this one lacks): {old.name}")
            continue
        size = subprocess.run(["du", "-sh", str(old)],
                              capture_output=True, text=True).stdout.split("\t")[0]
        print(f"  pruning older backup: {old.name} ({size})")
        shutil.rmtree(old)


def lean_strip(usb: Path, backup: bool) -> dict:
    """Back up (optional) and remove everything pre-Rekordbox players waste time
    pre-reading: the PIONEER rekordbox database and the Contents/ audio tree.
    Keeps Playlists/ only. Rekordbox re-sync regenerates PIONEER+Contents."""
    hot = recent_write(usb)
    if hot and not forced():
        raise SystemExit(f"REFUSE: {usb.name} was written in the last 90s:\n"
                         f"   {hot}\n"
                         f"   Rekordbox Sync Manager is probably still exporting — "
                         f"stripping now corrupts the sync.\n"
                         f"   Wait for it to stop, or set CDJ400_FORCE=1 to override.")
    stamp = time.strftime("%Y%m%d-%H%M%S")
    base = Path.home() / "Music" / "DJ.CDJ400-BACKUPS" / f"{usb.name}-{stamp}"
    backup_root = base
    n = 0
    while backup_root.exists():  # never merge two runs into one backup dir
        n += 1
        backup_root = base.with_name(f"{base.name}-{n}")
    result = {"stripped": [], "backup_path": None}
    parts: list[str] = []
    total = 0
    for name in ("PIONEER", "Contents"):
        src = usb / name
        if not src.exists():
            continue
        if backup:
            dst = backup_root / name
            dst.mkdir(parents=True, exist_ok=True)
            subprocess.run(["rsync", "-a", "--checksum",
                            str(src) + "/", str(dst) + "/"],
                           check=True)
            n_src = sum(1 for p in src.rglob("*") if p.is_file())
            n_dst = sum(1 for p in dst.rglob("*") if p.is_file())
            if n_src != n_dst:
                raise SystemExit(f"backup verify FAILED for {name}: "
                                 f"{n_src} vs {n_dst} — stick untouched")
            result["backup_path"] = str(backup_root)
            parts.append(name)
            total += n_src
            print(f"  backed up {name}: {n_src} files -> {dst}")
        shutil.rmtree(src)
        result["stripped"].append(name)
        print(f"  stripped {name} from stick")
    if result["backup_path"]:
        root = Path(result["backup_path"])
        (root / ".complete").write_text(
            f"stick={usb.name}\nparts={','.join(parts)}\nfiles={total}\n"
            f"written={stamp}\n")
        print(f"  marker: {root / '.complete'}")
        prune_older_backups(usb.name, root)
    return result


def main():
    ap = argparse.ArgumentParser(description="CDJ-400 USB finalizer")
    ap.add_argument("xml", type=Path)
    ap.add_argument("usb", type=Path)
    ap.add_argument("--only", default="",
                    help="comma-separated playlist names to build (default: all)")
    ap.add_argument("--skip-over", type=int, default=500,
                    help="skip playlists with more refs than this (no on-player search)")
    ap.add_argument("--lean", action="store_true",
                    help="after building Playlists/, strip PIONEER/ + Contents/ "
                         "(pre-Rekordbox decks pre-read everything; fewer files = "
                         "faster insert-to-play). Modern players need a re-sync.")
    ap.add_argument("--no-backup", action="store_true",
                    help="with --lean: skip Mac-side backup (regenerable by re-sync)")
    args = ap.parse_args()
    check_volume(args.usb)
    tracks, playlists = parse_xml(args.xml)
    print(f"collection: {len(tracks)} tracks, {len(playlists)} playlists in XML")
    wanted = {p.strip() for p in args.only.split(",") if p.strip()}

    # Fail fast on the space trap: the render (Playlists/) lands on the stick
    # BEFORE the --lean strip frees PIONEER/+Contents/, so the render must fit
    # alongside a full export. Refuse cleanly instead of dying mid-copy with
    # "No space left on device".
    need = 0
    for name, keys in playlists:
        if wanted and name not in wanted:
            continue
        if len(keys) > args.skip_over:
            continue
        seen = set()
        for key in keys:
            t = tracks.get(key)
            if not t or t["location"] is None or not t["location"].is_file():
                continue
            if t["location"].suffix.lower() != ".mp3":
                continue
            s = str(t["location"])
            if s in seen:
                continue
            seen.add(s)
            need += t["location"].stat().st_size
    free = shutil.disk_usage(args.usb).free
    dest_root = args.usb / "Playlists"
    if dest_root.exists():  # the render wipes it before copying — that space comes back
        free += sum(f.stat().st_size for f in dest_root.rglob("*") if f.is_file())
    required = int(need * 1.05) + (100 << 20)  # FAT slack + sidecars + manifest
    if required > free:
        print(f"\nNOT ENOUGH SPACE: the render needs ~{need/1e9:.1f} GB "
              f"(+headroom) but {args.usb} has only {free/1e9:.1f} GB free.")
        print("  The export and the Playlists/ render don't fit together.")
        print("  Free the export first (backed up + verified), then rerun:")
        print(f"    cdj400-prestrip {args.usb}")
        sys.exit(2)

    dest_root = args.usb / "Playlists"
    if dest_root.exists():
        shutil.rmtree(dest_root)
    dest_root.mkdir()

    manifest = {"playlists": {}, "skipped_non_mp3": [], "missing": [],
                "out_of_spec": [], "skipped_big": []}
    total_copied = 0
    for name, keys in playlists:
        if wanted and name not in wanted:
            continue
        if len(keys) > args.skip_over:
            manifest["skipped_big"].append({"playlist": name, "refs": len(keys)})
            print(f"SKIP (mega-playlist, {len(keys)} refs): {name}")
            continue
        folder = dest_root / fat32_safe(name)
        folder.mkdir(exist_ok=True)
        seen_src, seen_name, copied = set(), set(), 0
        for key in keys:
            t = tracks.get(key)
            if not t:
                continue
            src = t["location"]
            if src is None or not src.is_file():
                manifest["missing"].append({"playlist": name, "key": key})
                continue
            if src.suffix.lower() != ".mp3":
                manifest["skipped_non_mp3"].append(
                    {"playlist": name, "file": str(src)})
                continue
            if str(src) in seen_src:
                continue  # same track twice in one playlist
            seen_src.add(str(src))
            dest_name = fat32_safe(src.name)
            n = 2
            while dest_name.lower() in seen_name:
                stem, dot, ext = src.name.rpartition(".")
                dest_name = fat32_safe(f"{stem} [{n}].{ext}")
                n += 1
            seen_name.add(dest_name.lower())
            shutil.copy2(src, folder / dest_name)
            copied += 1
        manifest["playlists"][name] = copied
        total_copied += copied
        print(f"{name}: {copied}/{len(keys)}")
        if copied == 0:
            shutil.rmtree(folder)
            print(f"  -> empty playlist folder removed: {name}")

    purge_apple_junk(args.usb)  # MOVED: now runs after audit, before manifest

    # verify: probe every copied MP3 + recount
    bad = 0
    for f in dest_root.rglob("*.mp3"):
        rate, ok = audit_mp3(f)
        if not ok:
            bad += 1
            manifest["out_of_spec"].append({"file": str(f), "rate": rate})
    on_disk = sum(1 for _ in dest_root.rglob("*.mp3"))
    assert on_disk == total_copied, f"count mismatch: disk={on_disk} manifest={total_copied}"
    (dest_root / ".build-manifest.json").write_text(json.dumps(manifest, indent=1))

    # LAST filesystem write of the run: purge anything the manifest write just
    # regrew (writing a file on FAT32 via macOS creates a fresh ._ sidecar).
    purge_apple_junk(args.usb)

    if args.lean:
        print("\n=== LEAN MODE: stripping PIONEER/ + Contents/ ===")
        lean = lean_strip(args.usb, backup=not args.no_backup)
        manifest["lean"] = lean
        # rewrite manifest + purge again (the rewrite regrows a sidecar)
        (dest_root / ".build-manifest.json").write_text(
            json.dumps(manifest, indent=1))
        purge_apple_junk(args.usb)
        print(f"  lean strip: removed {lean['stripped'] or 'nothing (already lean)'}")

    print(f"\nDONE: {total_copied} MP3s in {len(manifest['playlists'])} folders, "
          f"{len(manifest['skipped_non_mp3'])} non-MP3 skipped, "
          f"{len(manifest['missing'])} missing, {bad} out-of-spec")
    if bad or manifest["missing"]:
        print("see .build-manifest.json for details")
        sys.exit(1)


if __name__ == "__main__":
    main()
