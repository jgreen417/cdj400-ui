"""Shared file-naming rules for the cdj400-* tools.

The CDJ-400's screen is tiny, so a lean stick can name its MP3s
"Artist - Title.mp3" from Rekordbox's own metadata instead of the
messy file names on the Mac. Every tool that names or matches files on a
lean stick goes through this module, so they all agree.

Each playlist folder can hold a `.cdj400-order.json`:

    {
      "names":    "tidy" | "original",   # how files are named (absent = original)
      "by":       "bpm" | "key" | null,  # how cdj400-sort ordered the folder
      "original": {current file name: the Mac file name it came from},
      "prefixed": [current file names that carry a "001 - " sort prefix]
    }

`original` only lists files whose name differs from the Mac name. Older
versions of cdj400-sort wrote only `by` and `original` (every renamed file
was then a prefixed one); `OrderFile` reads both shapes.

Python 3.9 compatible: it runs under the Xcode Command Line Tools python3.
"""
from __future__ import annotations

import json
import re
import unicodedata
from pathlib import Path

ORDER_FILE = ".cdj400-order.json"
MAX_BASENAME = 100          # characters, extension included
PREFIX = re.compile(r"^\d{3} - ")

# FAT32 refuses these. Separators turn into a dash so "AC/DC" stays readable.
_TO_DASH = {"/": "-", "\\": "-", "|": "-", ":": " -"}
_TO_QUOTE = {'"': "'"}
_DROP = set("<>?*")


def norm(name: str) -> str:
    """Comparison key: NFC-normalised and casefolded (FAT32 ignores case)."""
    return unicodedata.normalize("NFC", name).casefold()


def _clean(text: str) -> str:
    out = []
    for c in unicodedata.normalize("NFC", text or ""):
        if c.isspace():
            out.append(" ")
        elif c in _TO_DASH:
            out.append(_TO_DASH[c])
        elif c in _TO_QUOTE:
            out.append(_TO_QUOTE[c])
        elif c in _DROP or unicodedata.category(c).startswith("C"):
            continue                     # control and format characters
        else:
            out.append(c)
    return re.sub(r"\s+", " ", "".join(out)).strip()


def fat32_safe(name: str) -> str:
    """A FAT32-legal file name of at most MAX_BASENAME characters."""
    name = _clean(name).rstrip(". ")
    if len(name) > MAX_BASENAME:
        stem, dot, ext = name.rpartition(".")
        if dot and 0 < len(ext) <= 5:
            name = stem[: MAX_BASENAME - len(ext) - 1].rstrip(". ") + "." + ext
        else:
            name = name[:MAX_BASENAME].rstrip(". ")
    return name or "untitled"


def tidy_name(artist: str, title: str, original: str) -> str:
    """"Artist - Title.ext" from Rekordbox's metadata.

    No artist: just the title. No title: the original name, unchanged. A title
    that already starts with "Artist - " isn't doubled. "(Original Mix)" and
    other mix names stay, as they're part of the title."""
    ext = Path(original).suffix or ".mp3"
    artist, title = _clean(artist), _clean(title)
    if not title:
        return original
    if artist and norm(title).startswith(norm(artist) + " - "):
        artist = ""
    base = (f"{artist} - {title}" if artist else title).rstrip(". ")
    return fat32_safe(base + ext.lower())


def unique(name: str, taken: set) -> str:
    """`name`, or "name (2).mp3", "name (3).mp3"... if `taken` already has it.
    `taken` holds norm()ed names; the result is added to it."""
    stem, ext = Path(name).stem, Path(name).suffix
    candidate, n = name, 2
    while norm(candidate) in taken:
        suffix = f" ({n})"
        candidate = fat32_safe(stem[: MAX_BASENAME - len(ext) - len(suffix)] + suffix + ext)
        n += 1
    taken.add(norm(candidate))
    return candidate


def strip_prefix(name: str) -> str:
    return PREFIX.sub("", name, count=1)


class OrderFile:
    """A folder's .cdj400-order.json. Missing or unreadable means: original
    names, not sorted."""

    def __init__(self, folder: Path):
        self.folder = Path(folder)
        try:
            data = json.loads((self.folder / ORDER_FILE).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {}
        if not isinstance(data, dict):
            data = {}
        self.by = data.get("by") or None
        self.names = data.get("names") or "original"
        self.original = dict(data.get("original") or {})
        if "prefixed" in data:
            self.prefixed = set(data.get("prefixed") or [])
        else:   # written by an older cdj400-sort: every renamed file was prefixed
            self.prefixed = set(self.original) if self.by in ("bpm", "key") else set()

    @property
    def tidy(self) -> bool:
        return self.names == "tidy"

    def mac_name(self, current: str) -> str:
        """The Mac file name this file on the stick came from."""
        return self.original.get(current, current)

    def base(self, current: str) -> str:
        """The current name without its "001 - " sort prefix, if it has one."""
        return strip_prefix(current) if current in self.prefixed else current

    def save(self) -> None:
        """Writes the file, or removes it when it would say nothing."""
        path = self.folder / ORDER_FILE
        self.original = {k: v for k, v in self.original.items() if k != v}
        if not self.original and not self.prefixed and not self.by and not self.tidy:
            path.unlink(missing_ok=True)
            return
        data = {"names": self.names, "by": self.by,
                "original": dict(sorted(self.original.items())),
                "prefixed": sorted(self.prefixed)}
        path.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
        # macOS writes a ._ sidecar beside every file it creates on FAT.
        (self.folder / ("._" + ORDER_FILE)).unlink(missing_ok=True)


def mp3s(folder: Path) -> list:
    """The MP3s in a playlist folder, skipping hidden files and partial copies."""
    if not folder.is_dir():
        return []
    return sorted(p for p in folder.iterdir()
                  if p.is_file() and not p.name.startswith(".")
                  and p.suffix.lower() == ".mp3")


def load_metadata(xml: Path) -> dict:
    """{(norm(Mac file name), size): (artist, title)} from a Rekordbox XML,
    plus {(norm(name), None): ...} for lookups without a size."""
    import urllib.parse
    import urllib.request
    import xml.etree.ElementTree as ET

    found = {}
    collection = ET.parse(xml).getroot().find("COLLECTION")
    for tr in collection if collection is not None else []:
        loc = tr.get("Location", "")
        if not loc.startswith("file://"):
            continue
        p = Path(urllib.request.url2pathname(urllib.parse.urlparse(loc).path))
        meta = (tr.get("Artist") or "", tr.get("Name") or "")
        size = int(tr.get("Size") or 0)
        for n in {norm(p.name), norm(fat32_safe(p.name))}:
            found[(n, size)] = meta
            found.setdefault((n, None), meta)
    return found
