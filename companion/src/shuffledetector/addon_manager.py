"""Locate WoW installs and install/update the bundled addon."""

import functools
import os
import re
import shutil
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ADDON_NAME = "ShuffleDetector"
PLAN_FILE = "Plan.lua"  # written by the companion; kept across addon updates
ITEM_LIST_FILE = "ItemList.lua"  # likewise
VERSION_PLACEHOLDER = "@project-version@"  # in the repo .toc; the release workflow swaps in the tag
_REPO_ADDON = Path(__file__).resolve().parents[3] / "addon" / ADDON_NAME
_BUNDLED_ADDON = Path(__file__).resolve().parent / "_addon" / ADDON_NAME


def bundled_addon_dir():
    """Addon source: SHUFFLEDETECTOR_ADDON override, packaged copy, then the repo checkout."""
    env = os.environ.get("SHUFFLEDETECTOR_ADDON")
    for p in (Path(env) if env else None, _BUNDLED_ADDON, _REPO_ADDON):
        if p and (p / f"{ADDON_NAME}.toc").is_file():
            return p
    return None


def parse_version(text):
    """'0.1.0' -> (0, 1, 0); None if it is not a release number (e.g. 'dev-1a2b3c4')."""
    m = re.match(r"v?(\d+(?:\.\d+)*)", (text or "").strip())
    return tuple(int(p) for p in m.group(1).split(".")) if m else None


@functools.lru_cache(maxsize=1)
def dev_version():
    """'dev-<sha>' of the source checkout, or 'dev' when git is unavailable."""
    sha = ""
    try:
        r = subprocess.run(["git", "rev-parse", "--short=7", "HEAD"], cwd=_REPO_ADDON, capture_output=True,
                           text=True, timeout=5, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if r.returncode == 0:
            sha = r.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return f"dev-{sha}" if sha else "dev"


def resolve_version(version):
    """Replace the unstamped placeholder with the dev version."""
    return dev_version() if version == VERSION_PLACEHOLDER else version


def toc_version(addon_dir):
    toc = Path(addon_dir) / f"{ADDON_NAME}.toc"
    try:
        for line in toc.read_text(encoding="utf-8", errors="replace").splitlines():
            m = re.match(r"##\s*Version:\s*(.+)", line)
            if m:
                return m.group(1).strip()
    except OSError:
        pass
    return None


@dataclass
class Install:
    """One game client flavor, e.g. <root>/_classic_."""
    flavor: str
    addons_dir: Path

    @property
    def addon_dir(self):
        return self.addons_dir / ADDON_NAME

    @property
    def plan_file(self):
        return self.addon_dir / PLAN_FILE

    @property
    def item_list_file(self):
        return self.addon_dir / ITEM_LIST_FILE

    @property
    def installed_version(self):
        return toc_version(self.addon_dir) if self.addon_dir.is_dir() else None

    def __str__(self):
        return f"{self.flavor} ({self.addons_dir})"


def default_roots():
    roots = []
    env = os.environ.get("WOW_PATH")
    if env:
        roots.append(Path(env))
    if sys.platform == "win32":
        # The literal paths cover shells (Git Bash) that do not pass "ProgramFiles(x86)" to child processes.
        for base in (os.environ.get("ProgramFiles(x86)"), os.environ.get("ProgramFiles"),
                     "C:\\Program Files (x86)", "C:\\Program Files", "C:\\Games"):
            if base and (Path(base) / "World of Warcraft") not in roots:
                roots.append(Path(base) / "World of Warcraft")
    elif sys.platform == "darwin":
        roots.append(Path("/Applications/World of Warcraft"))
    else:
        home = Path.home()
        roots += [
            home / "Games" / "world-of-warcraft",
            home / ".wine" / "drive_c" / "Program Files (x86)" / "World of Warcraft",
        ]
    return roots


def installs_in(path):
    """Installs found at `path`: a WoW root, a flavor folder, or an AddOns folder."""
    path = Path(path)
    if path.name.lower() == "addons" and path.is_dir():
        return [Install(path.parent.parent.name, path)]
    if (path / "Interface" / "AddOns").is_dir():
        return [Install(path.name, path / "Interface" / "AddOns")]
    if not path.is_dir():
        return []
    return [
        Install(d.name, d / "Interface" / "AddOns")
        for d in sorted(path.iterdir())
        if d.is_dir() and (d / "Interface" / "AddOns").is_dir()
    ]


def discover_installs(extra_roots=()):
    seen, found = set(), []
    for root in (*map(Path, extra_roots), *default_roots()):
        for inst in installs_in(root):
            key = str(inst.addons_dir).lower()
            if key not in seen:
                seen.add(key)
                found.append(inst)
    return found


def status(install):
    """'not_installed' | 'up_to_date' | 'outdated' | 'newer' | 'no_bundle'.

    Dev builds ('dev-<sha>') cannot be ordered: a dev bundle replaces any different install, and a
    dev install is never replaced by a release bundle.
    """
    src = bundled_addon_dir()
    if src is None:
        return "no_bundle"
    have_s = install.installed_version
    if have_s is None:
        return "not_installed"
    want_s = resolve_version(toc_version(src))
    if have_s == want_s:
        return "up_to_date"
    have, want = parse_version(have_s), parse_version(want_s)
    if want is None:
        return "outdated"
    if have is None:
        return "newer" if have_s.startswith("dev") else "outdated"
    return "outdated" if have < want else "newer"


def install_addon(install):
    """Copy the bundled addon into the AddOns folder (swap in place; SavedVariables live in WTF, untouched).
    A previously sent Plan.lua and ItemList.lua are carried over."""
    src = bundled_addon_dir()
    if src is None:
        raise FileNotFoundError("Bundled addon files not found.")
    target = install.addon_dir
    tmp = install.addons_dir / f".{ADDON_NAME}.new"
    old = install.addons_dir / f".{ADDON_NAME}.old"
    for p in (tmp, old):
        _remove_tree(p)
    shutil.copytree(src, tmp, copy_function=shutil.copyfile)
    toc = tmp / f"{ADDON_NAME}.toc"
    stamped = toc.read_bytes().replace(VERSION_PLACEHOLDER.encode(), dev_version().encode())
    toc.write_bytes(stamped)
    for kept, name in ((install.plan_file, PLAN_FILE), (install.item_list_file, ITEM_LIST_FILE)):
        try:
            if kept.is_file():
                shutil.copyfile(kept, tmp / name)
        except OSError:
            pass
    try:
        if target.exists():
            target.rename(old)
        tmp.rename(target)
    except OSError:
        if old.exists() and not target.exists():
            old.rename(target)
        _remove_tree(tmp)
        raise
    _remove_tree(old)
    return install.installed_version


def _remove_tree(path):
    """rmtree that also clears read-only attributes (which block deletion on Windows)."""
    def onerror(func, p, _exc):
        try:
            os.chmod(p, stat.S_IWRITE)
            func(p)
        except OSError:
            pass
    shutil.rmtree(path, onerror=onerror)
