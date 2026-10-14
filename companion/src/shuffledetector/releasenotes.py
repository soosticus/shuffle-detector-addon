"""Release notes shipped with the companion (release-notes/vX.Y.Z.md in the repo)."""

import os
import re
from pathlib import Path

from . import addon_manager

_PACKAGED = Path(__file__).resolve().parent / "_release_notes"
_REPO = Path(__file__).resolve().parents[3] / "release-notes"
_NAME = re.compile(r"^v?(\d+(?:\.\d+)*)\.md$")


def notes_dir():
    """SHUFFLEDETECTOR_NOTES override, the packaged copy, then the repo checkout; None if there are none."""
    env = os.environ.get("SHUFFLEDETECTOR_NOTES")
    for p in (Path(env) if env else None, _PACKAGED, _REPO):
        if p and p.is_dir() and any(_NAME.match(f.name) for f in p.iterdir()):
            return p
    return None


def all_notes():
    """[(version tuple, 'X.Y.Z', markdown)] newest first."""
    folder = notes_dir()
    if folder is None:
        return []
    found = []
    for f in folder.iterdir():
        m = _NAME.match(f.name)
        if not m:
            continue
        try:
            text = f.read_text(encoding="utf-8")
        except OSError:
            continue
        found.append((addon_manager.parse_version(m.group(1)), m.group(1), text))
    return sorted(found, reverse=True)


def unseen_notes(last_seen, current):
    """Notes for versions after `last_seen` up to `current`; only `current`'s when nothing was seen before."""
    cur, seen = addon_manager.parse_version(current), addon_manager.parse_version(last_seen)
    if cur is None:
        return []
    return [n for n in all_notes() if n[0] <= cur and (seen is None and n[0] == cur or seen is not None and n[0] > seen)]
