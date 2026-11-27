"""End-to-end tests for the cdj400-* tools against a fake stick and library.

Run:  python3 -m unittest discover -s Tests/tools -v
(also run by `swift test` through the PythonToolTests suite).

Each test builds, in a temporary HOME:
  - a "Mac" music library with messy file names,
  - a Rekordbox-style XML (what cdj400-dbexport writes),
  - a stick in Rekordbox export mode: PIONEER/ + Contents/<Artist>/<Album>/,
and puts stand-ins for macOS-only commands (dot_clean, mdutil, diskutil, and
rsync when it's missing) first on PATH, so nothing real is touched.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from urllib.parse import quote

TOOLS = Path(__file__).resolve().parents[2] / "tools"
sys.path.insert(0, str(TOOLS))
sys.dont_write_bytecode = True
from cdj400_names import OrderFile, fat32_safe, tidy_name, unique  # noqa: E402

FAKE_BIN = {
    "dot_clean": "#!/bin/sh\nexit 0\n",
    "mdutil": "#!/bin/sh\nexit 0\n",
    # `diskutil info -plist <mount>`: the stick's UUID lives in <mount>/.fakeuuid
    "diskutil": """#!/bin/sh
u=$(cat "$3/.fakeuuid" 2>/dev/null || echo)
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>VolumeUUID</key><string>%s</string></dict></plist>' "$u"
""",
}
FAKE_RSYNC = """#!/bin/sh
# enough of `rsync -a [--checksum] SRC/ DST/` for these tests: the last two args
eval "src=\\${$(($# - 1))}"; eval "dst=\\${$#}"
mkdir -p "$dst" && cp -a "$src". "$dst"
"""

# id: (mac file name, artist, title, bpm, key)
TRACKS = {
    "1": ("01 - dj_shadow-midnight_in_a_perfect_world (original mix) [www.xyz].mp3",
          "DJ Shadow", "Midnight in a Perfect World (Original Mix)", 96.0, "Am"),
    "2": ("track02_final_MASTER.mp3", "Ricardo Villalobos", "Dexter", 124.0, "Fm"),
    "3": ("untitled_rip.mp3", "", "", 0.0, ""),
    "4": ("AC_DC thing.mp3", "AC/DC", "Back: In Black?", 92.0, "E"),
    "7": ("only_on_mac.mp3", "Zip", "Not Exported", 128.0, "Cm"),
    "8": ("new_one_v3.mp3", "Margaret Dygas", "Rose Blue", 122.0, "Dm"),
}
PLAYLISTS = {"Warmup": ["1", "2", "3", "4"], "Peak": ["2", "7"]}


class Env:
    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="cdj400-tools-"))
        self.home = self.root / "home"
        self.lib = self.home / "Music" / "lib"
        self.lib.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        scripts = dict(FAKE_BIN)
        if shutil.which("rsync") is None:
            scripts["rsync"] = FAKE_RSYNC
        for name, body in scripts.items():
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                        TMPDIR=str(self.root / "tmp"),
                        # the fake stick was "written" seconds ago; with Rekordbox
                        # open on the test Mac the 90 s safety check would refuse it
                        CDJ400_FORCE="1",
                        CDJ400_VOLUMES=str(self.root / "Volumes"))
        (self.root / "tmp").mkdir()
        for i, (name, *_rest) in TRACKS.items():
            # distinct sizes, so size-checks can tell tracks apart
            (self.lib / name).write_bytes(bytes([int(i)]) * (1000 + 37 * int(i)))
        self.playlists = {k: list(v) for k, v in PLAYLISTS.items()}

    def size(self, i):
        return (self.lib / TRACKS[i][0]).stat().st_size

    def write_xml(self) -> Path:
        xml = self.root / "library.xml"
        rows = []
        for i, (name, artist, title, bpm, key) in TRACKS.items():
            loc = "file://localhost" + quote(str(self.lib / name))
            rows.append(f'<TRACK TrackID="{i}" Name="{title}" Artist="{artist}" Location="{loc}"'
                        f' Size="{self.size(i)}" Kind="MP3 File" AverageBpm="{bpm}"'
                        f' Tonality="{key}"/>')
        nodes = "".join(
            f'<NODE Name="{n}" Type="1" KeyType="0" Entries="{len(ids)}">'
            + "".join(f'<TRACK Key="{i}"/>' for i in ids) + "</NODE>"
            for n, ids in self.playlists.items())
        xml.write_text('<?xml version="1.0" encoding="UTF-8"?><DJ_PLAYLISTS Version="1.0.0">'
                       f'<COLLECTION Entries="{len(rows)}">{"".join(rows)}</COLLECTION>'
                       f'<PLAYLISTS><NODE Type="0" Name="ROOT">{nodes}</NODE></PLAYLISTS>'
                       "</DJ_PLAYLISTS>")
        return xml

    def make_stick(self, name="DECK", uuid="UUID-DECK") -> Path:
        usb = self.root / "Volumes" / name
        (usb / "PIONEER" / "rekordbox").mkdir(parents=True)
        (usb / "PIONEER" / "rekordbox" / "export.pdb").write_bytes(b"pdb" * 100)
        (usb / "PIONEER" / "USBANLZ").mkdir()
        (usb / "PIONEER" / "USBANLZ" / "ANLZ0001.DAT").write_bytes(b"anlz" * 50)
        exported = {"1", "2", "3", "4"}        # 7 and 8 never reached the stick
        for i in exported:
            artist = TRACKS[i][1] or "Unknown Artist"
            d = usb / "Contents" / artist.replace("/", "") / "Album"
            d.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.lib / TRACKS[i][0], d / TRACKS[i][0])
        stale = usb / "Contents" / "Old" / "Old"
        stale.mkdir(parents=True)
        (stale / "stale.mp3").write_bytes(b"s" * 555)
        (usb / ".fakeuuid").write_text(uuid)
        return usb

    def run(self, tool, *args, ok=True):
        r = subprocess.run([sys.executable, str(TOOLS / tool), *map(str, args)],
                           capture_output=True, text=True, env=self.env)
        out = r.stdout + r.stderr
        if ok and r.returncode != 0:
            raise AssertionError(f"{tool} {args} failed ({r.returncode}):\n{out}")
        return r.returncode, out

    def status(self, usb, xml):
        _, out = self.run("cdj400-addplaylist", usb, "--status", "--xml", xml)
        rows = [line.split("\t") for line in out.splitlines() if line.count("\t") == 4]
        return {r[0]: (int(r[2]), int(r[3])) for r in rows}

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


def names(folder: Path):
    return sorted(p.name for p in folder.iterdir() if not p.name.startswith("."))


class NamingRules(unittest.TestCase):
    def test_artist_dash_title(self):
        self.assertEqual(tidy_name("DJ Shadow", "Midnight (Original Mix)", "x.MP3"),
                         "DJ Shadow - Midnight (Original Mix).mp3")

    def test_fallbacks(self):
        self.assertEqual(tidy_name("", "Dexter", "a.mp3"), "Dexter.mp3")
        self.assertEqual(tidy_name("Someone", "", "messy_01.mp3"), "messy_01.mp3")
        self.assertEqual(tidy_name("Moodymann", "Moodymann - Shades", "a.mp3"),
                         "Moodymann - Shades.mp3")

    def test_fat32_characters(self):
        self.assertEqual(tidy_name("AC/DC", 'Back: In "Black"?', "a.mp3"),
                         "AC-DC - Back - In 'Black'.mp3")
        self.assertEqual(tidy_name("  A\tB ", "Song​.", "a.mp3"), "A B - Song.mp3")

    def test_length_cap_keeps_extension(self):
        name = tidy_name("A" * 80, "B" * 80, "a.mp3")
        self.assertLessEqual(len(name), 100)
        self.assertTrue(name.endswith(".mp3"))
        self.assertEqual(fat32_safe("x" * 120 + ".mp3")[-4:], ".mp3")

    def test_unique_is_case_insensitive(self):
        taken = set()
        self.assertEqual(unique("A - B.mp3", taken), "A - B.mp3")
        self.assertEqual(unique("a - b.mp3", taken), "a - b (2).mp3")
        self.assertEqual(unique("A - B.mp3", taken), "A - B (3).mp3")

    def test_reads_old_sort_files(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, ".cdj400-order.json").write_text(json.dumps(
                {"by": "bpm", "original": {"001 - x.mp3": "x.mp3"}}))
            order = OrderFile(Path(d))
            self.assertFalse(order.tidy)
            self.assertEqual(order.base("001 - x.mp3"), "x.mp3")
            self.assertEqual(order.mac_name("001 - x.mp3"), "x.mp3")


class LeanRoundTrip(unittest.TestCase):
    def setUp(self):
        self.e = Env()
        self.xml = self.e.write_xml()
        self.usb = self.e.make_stick()
        self.contents_before = {
            str(p.relative_to(self.usb)): p.stat().st_size
            for p in (self.usb / "Contents").rglob("*") if p.is_file()}

    def tearDown(self):
        self.e.close()

    def make_lean(self, *extra):
        return self.e.run("cdj400-adopt", self.xml, self.usb, "--execute", "--force", *extra)

    def test_dry_run_changes_nothing_and_previews_names(self):
        _, out = self.e.run("cdj400-adopt", self.xml, self.usb, "--tidy-names", "--force")
        self.assertIn("-> DJ Shadow - Midnight in a Perfect World (Original Mix).mp3", out)
        self.assertTrue((self.usb / "Contents").is_dir())
        self.assertFalse((self.usb / "Playlists").exists())
        self.assertFalse((self.e.home / "Music" / "DJ.CDJ400-BACKUPS").exists())

    def test_tidy_make_lean(self):
        self.make_lean("--tidy-names")
        warm = self.usb / "Playlists" / "Warmup"
        self.assertEqual(names(warm), [
            "AC-DC - Back - In Black.mp3",
            "DJ Shadow - Midnight in a Perfect World (Original Mix).mp3",
            "Ricardo Villalobos - Dexter.mp3",
            "untitled_rip.mp3",
        ])
        self.assertEqual(names(self.usb / "Playlists" / "Peak"),
                         ["Ricardo Villalobos - Dexter.mp3", "Zip - Not Exported.mp3"])
        self.assertFalse((self.usb / "PIONEER").exists())
        self.assertFalse((self.usb / "Contents").exists())
        order = OrderFile(warm)
        self.assertTrue(order.tidy)
        self.assertEqual(order.mac_name("Ricardo Villalobos - Dexter.mp3"), "track02_final_MASTER.mp3")
        # every folder matches Rekordbox: nothing to copy, nothing to prune
        self.assertEqual(self.e.status(self.usb, self.xml), {"Peak": (0, 0), "Warmup": (0, 0)})

    def test_original_names_still_default(self):
        self.make_lean()
        self.assertIn("track02_final_MASTER.mp3", names(self.usb / "Playlists" / "Warmup"))
        self.assertFalse(OrderFile(self.usb / "Playlists" / "Warmup").tidy)

    def test_sort_and_rename_keep_every_track_matched(self):
        self.make_lean("--tidy-names")
        warm = self.usb / "Playlists" / "Warmup"
        self.e.run("cdj400-sort", self.usb, "--by", "bpm", "--folder", "Warmup",
                   "--xml", self.xml, "--execute")
        self.assertEqual(names(warm)[0], "001 - AC-DC - Back - In Black.mp3")   # 92 BPM
        self.assertEqual(self.e.status(self.usb, self.xml)["Warmup"], (0, 0))

        self.e.run("cdj400-rename", self.usb, "--original", "--execute")
        self.assertIn("001 - AC_DC thing.mp3", names(warm))
        self.assertEqual(self.e.status(self.usb, self.xml)["Warmup"], (0, 0))

        self.e.run("cdj400-rename", self.usb, "--tidy", "--xml", self.xml, "--execute")
        self.assertIn("001 - AC-DC - Back - In Black.mp3", names(warm))
        self.assertIn("Zip - Not Exported.mp3", names(self.usb / "Playlists" / "Peak"))
        self.assertEqual(self.e.status(self.usb, self.xml), {"Peak": (0, 0), "Warmup": (0, 0)})

        # Sort by name drops the prefixes but keeps the tidy names.
        self.e.run("cdj400-sort", self.usb, "--by", "name", "--xml", self.xml, "--execute")
        self.assertEqual(names(warm)[0], "AC-DC - Back - In Black.mp3")
        self.assertTrue(OrderFile(warm).tidy)
        self.assertEqual(self.e.status(self.usb, self.xml)["Warmup"], (0, 0))

    def test_update_copies_new_tracks_tidy_and_never_prunes_renamed_ones(self):
        self.make_lean("--tidy-names")
        self.e.run("cdj400-sort", self.usb, "--by", "bpm", "--xml", self.xml, "--execute")
        self.e.playlists["Warmup"] = ["1", "2", "3", "8"]          # 4 out, 8 in
        xml = self.e.write_xml()
        self.assertEqual(self.e.status(self.usb, xml)["Warmup"], (1, 1))
        _, out = self.e.run("cdj400-addplaylist", self.usb, "Warmup", "--xml", xml,
                            "--execute", "--prune")
        self.assertIn("1 to copy", out)
        warm = names(self.usb / "Playlists" / "Warmup")
        self.assertEqual(len(warm), 4)
        self.assertFalse(any("AC-DC" in n for n in warm))
        self.assertTrue(any(n.endswith("Margaret Dygas - Rose Blue.mp3") for n in warm), warm)
        self.assertTrue(all(n[:6].strip(" -").isdigit() for n in warm), warm)  # re-sorted
        self.assertEqual(self.e.status(self.usb, xml)["Warmup"], (0, 0))

    def test_new_playlist_gets_tidy_names_with_flag(self):
        self.make_lean("--tidy-names")
        self.e.playlists["Fresh"] = ["8", "3"]
        xml = self.e.write_xml()
        self.e.run("cdj400-addplaylist", self.usb, "Fresh", "--xml", xml, "--execute",
                   "--tidy-names")
        self.assertEqual(names(self.usb / "Playlists" / "Fresh"),
                         ["Margaret Dygas - Rose Blue.mp3", "untitled_rip.mp3"])
        self.assertEqual(self.e.status(self.usb, xml)["Fresh"], (0, 0))

    def test_restore_moves_everything_back_exactly(self):
        self.make_lean("--tidy-names")
        self.e.run("cdj400-sort", self.usb, "--by", "key", "--xml", self.xml, "--execute")
        # Remove a track from the stick (as a prune would): restore copies it from the Mac.
        warm = self.usb / "Playlists" / "Warmup"
        next(p for p in warm.iterdir() if "AC-DC" in p.name).unlink()

        _, out = self.e.run("cdj400-restore", self.usb, "--dry-run")
        self.assertIn("3 files move back", out)
        self.assertIn("1 files copy from the Mac", out)
        self.assertTrue((self.usb / "Playlists").is_dir())

        self.e.run("cdj400-restore", self.usb)
        after = {str(p.relative_to(self.usb)): p.stat().st_size
                 for p in (self.usb / "Contents").rglob("*") if p.is_file()}
        self.assertEqual(after, self.contents_before)
        self.assertEqual((self.usb / "PIONEER/rekordbox/export.pdb").read_bytes(), b"pdb" * 100)
        self.assertTrue((self.usb / "PIONEER/USBANLZ/ANLZ0001.DAT").is_file())
        self.assertFalse((self.usb / "Playlists").exists())

    def test_restore_refuses_another_sticks_backup(self):
        self.make_lean()
        (self.usb / ".fakeuuid").write_text("UUID-SOMETHING-ELSE")
        code, out = self.e.run("cdj400-restore", self.usb, ok=False)
        self.assertEqual(code, 1)
        self.assertIn("different stick", out)
        self.assertFalse((self.usb / "Contents").exists())

    def test_restore_refuses_a_missing_backup(self):
        self.make_lean()
        shutil.rmtree(self.e.home / "Music" / "DJ.CDJ400-BACKUPS")
        code, out = self.e.run("cdj400-restore", self.usb, ok=False)
        self.assertEqual(code, 1)
        self.assertIn("missing or incomplete", out)
        self.assertIn("Sync Manager", out)

    def test_making_lean_again_prunes_the_older_backup(self):
        self.make_lean()
        self.e.run("cdj400-restore", self.usb)
        self.make_lean()
        backups = list((self.e.home / "Music" / "DJ.CDJ400-BACKUPS").iterdir())
        self.assertEqual(len(backups), 1)
        marker = json.loads((self.usb / "Playlists" / ".cdj400-lean.json").read_text())
        self.assertEqual(marker["backup"], backups[0].name)


class Backups(unittest.TestCase):
    def setUp(self):
        self.e = Env()
        self.xml = self.e.write_xml()
        self.usb = self.e.make_stick()
        self.e.run("cdj400-adopt", self.xml, self.usb, "--execute", "--force")
        self.root = self.e.home / "Music" / "DJ.CDJ400-BACKUPS"
        self.lean_backup = json.loads((self.usb / "Playlists" / ".cdj400-lean.json").read_text())["backup"]
        for name, complete in [("DECK-20200101-000000", True), ("GONE-20250101-000000", True),
                               ("SPARE-20250101-000000", False)]:
            (self.root / name / "Contents").mkdir(parents=True)
            (self.root / name / "Contents" / "a.mp3").write_bytes(b"a" * 2000)
            if complete:
                (self.root / name / ".complete").write_text("x")

    def tearDown(self):
        self.e.close()

    def listing(self):
        _, out = self.e.run("cdj400-backups", "--list")
        rows = [line.split("\t") for line in out.splitlines()]
        self.assertTrue(all(len(r) == 7 for r in rows), rows)
        return {r[0]: r for r in rows}

    def test_statuses(self):
        rows = self.listing()
        self.assertEqual(rows[self.lean_backup][4:6], ["lean", "in-use"])
        self.assertEqual(rows[self.lean_backup][6], "UUID-DECK")
        self.assertEqual(rows["DECK-20200101-000000"][4:6], ["full", "older"])
        self.assertEqual(rows["GONE-20250101-000000"][5], "latest")
        self.assertEqual(rows["SPARE-20250101-000000"][4:6], ["partial", "incomplete"])
        self.assertGreater(int(rows["GONE-20250101-000000"][3]), 1999)

    def test_never_deletes_a_backup_a_plugged_in_stick_needs(self):
        code, out = self.e.run("cdj400-backups", "--delete", self.lean_backup,
                               "DECK-20200101-000000", "--execute", ok=False)
        self.assertEqual(code, 1)
        self.assertIn("restores from it", out)
        self.assertTrue((self.root / self.lean_backup).is_dir())
        self.assertFalse((self.root / "DECK-20200101-000000").exists())

    def test_refuses_paths_outside_the_folder(self):
        code, out = self.e.run("cdj400-backups", "--delete", "../lib", "--execute", ok=False)
        self.assertEqual(code, 1)
        self.assertTrue(self.e.lib.is_dir())

    def test_dry_run_deletes_nothing(self):
        self.e.run("cdj400-backups", "--delete", "GONE-20250101-000000")
        self.assertTrue((self.root / "GONE-20250101-000000").is_dir())

    def test_backup_not_needed_once_the_stick_is_restored(self):
        self.e.run("cdj400-restore", self.usb)
        self.assertEqual(self.listing()[self.lean_backup][5], "not-needed")


class LegacyRestore(unittest.TestCase):
    """Sticks made lean before the marker existed."""

    def setUp(self):
        self.e = Env()
        self.usb = self.e.root / "Volumes" / "OLD"
        (self.usb / "Playlists" / "A").mkdir(parents=True)
        (self.usb / "Playlists" / "A" / "x.mp3").write_bytes(b"x" * 10)
        self.backups = self.e.home / "Music" / "DJ.CDJ400-BACKUPS"

    def tearDown(self):
        self.e.close()

    def backup(self, name):
        b = self.backups / name
        (b / "Contents" / "X").mkdir(parents=True)
        (b / "Contents" / "X" / "x.mp3").write_bytes(b"x" * 10)
        (b / "PIONEER").mkdir()
        (b / "PIONEER" / "export.pdb").write_bytes(b"p")
        (b / ".complete").write_text("stick=OLD\n")
        return b

    def test_refuses_a_backup_from_long_before(self):
        self.backup("OLD-20200101-000000")
        code, out = self.e.run("cdj400-restore", self.usb, ok=False)
        self.assertEqual(code, 1)
        self.assertIn("days", out)
        self.assertFalse((self.usb / "Contents").exists())
        self.e.run("cdj400-restore", self.usb, "--allow-old")
        self.assertTrue((self.usb / "Contents" / "X" / "x.mp3").is_file())

    def test_accepts_a_matching_backup_and_ignores_similar_names(self):
        import time
        now = time.strftime("%Y%m%d-%H%M%S")
        self.backup(f"OLD-{now}")
        other = self.backup(f"OLD-B-{now}")          # another stick, "OLD-B"
        (other / "PIONEER" / "export.pdb").write_bytes(b"other")
        self.e.run("cdj400-restore", self.usb)
        self.assertEqual((self.usb / "PIONEER" / "export.pdb").read_bytes(), b"p")
        self.assertFalse((self.usb / "Playlists").exists())


if __name__ == "__main__":
    unittest.main()
