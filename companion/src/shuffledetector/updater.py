"""Check GitHub releases for a newer companion app and a newer addon build.

Only meaningful for packaged builds: when running from a source checkout the repo's own addon is used.
"""

import io
import json
import os
import urllib.request
import zipfile
from pathlib import Path

from . import __version__, addon_manager

GITHUB_REPO = os.environ.get("SHUFFLEDETECTOR_REPO", "soosticus/ShuffleDetector")
ADDON_ASSET_PREFIX = "ShuffleDetector-"
COMPANION_ASSET_PREFIX = "ShuffleDetector-Companion"


def from_source_tree():
    return (addon_manager._REPO_ADDON / f"{addon_manager.ADDON_NAME}.toc").is_file()


def cache_dir():
    base = os.environ.get("LOCALAPPDATA") or os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "ShuffleDetector" / "addon-release"


def _get(url, timeout=10):
    req = urllib.request.Request(url, headers={"User-Agent": "ShuffleDetector-updater", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def latest_release():
    """Latest published release as a dict {tag, url, assets: {name: download_url}}."""
    data = json.loads(_get(f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest"))
    return {
        "tag": data["tag_name"],
        "url": data["html_url"],
        "assets": {a["name"]: a["browser_download_url"] for a in data.get("assets", [])},
    }


def app_update_available(release):
    have, want = addon_manager.parse_version(__version__), addon_manager.parse_version(release["tag"].lstrip("v"))
    return bool(have and want and want > have)


def download_addon(release):
    """Download the release's addon zip, unpack to the cache and point the addon manager at it.

    Returns the addon version now in use, or None if the release has no addon asset or is not newer.
    """
    url = next((u for n, u in release["assets"].items() if n.startswith(ADDON_ASSET_PREFIX) and not n.startswith(COMPANION_ASSET_PREFIX) and n.endswith(".zip")), None)
    if not url:
        return None
    target = cache_dir()
    with zipfile.ZipFile(io.BytesIO(_get(url, timeout=60))) as zf:
        names = zf.namelist()
        if not any(n.startswith(f"{addon_manager.ADDON_NAME}/") for n in names):
            return None
        addon_manager._remove_tree(target)
        target.mkdir(parents=True, exist_ok=True)
        for n in names:  # refuse paths that escape the cache folder
            if os.path.isabs(n) or ".." in Path(n).parts:
                return None
        zf.extractall(target)
    new = target / addon_manager.ADDON_NAME
    current = addon_manager.bundled_addon_dir()
    new_v = addon_manager.parse_version(addon_manager.toc_version(new))
    cur_v = addon_manager.parse_version(addon_manager.toc_version(current)) if current else None
    if new_v is None or (cur_v is not None and new_v <= cur_v):
        return None
    os.environ["SHUFFLEDETECTOR_ADDON"] = str(new)
    return addon_manager.toc_version(new)


def use_cached_addon():
    """At startup, prefer a previously downloaded addon if it is newer than the packaged one."""
    cached = cache_dir() / addon_manager.ADDON_NAME
    if not (cached / f"{addon_manager.ADDON_NAME}.toc").is_file():
        return
    packaged = addon_manager._BUNDLED_ADDON
    new_v = addon_manager.parse_version(addon_manager.toc_version(cached))
    cur_v = addon_manager.parse_version(addon_manager.toc_version(packaged)) if packaged.is_dir() else None
    if new_v and (cur_v is None or new_v > cur_v):
        os.environ.setdefault("SHUFFLEDETECTOR_ADDON", str(cached))
