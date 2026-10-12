"""Load addon scan data and reference data (items, vendor prices, recipes)."""

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

from . import addon_manager, luaparse

SAVED_VARIABLES_NAME = "AHSnapshotDB"
UNLIMITED_QTY = 10**9
ADDON_FILE = "ShuffleDetector.lua"
# Shared reference data lives in <repo>/common/data (companion/src/shuffledetector/ is 4 levels down).
_PACKAGED_DATA = Path(__file__).resolve().parent / "_data"
_REPO_DATA = Path(__file__).resolve().parents[3] / "common" / "data"
DEFAULT_REFERENCE = Path(os.environ.get(
    "SHUFFLEDETECTOR_DATA",
    (_PACKAGED_DATA if (_PACKAGED_DATA / "reference.json").is_file() else _REPO_DATA) / "reference.json",
))


@dataclass
class Reference:
    items: dict = field(default_factory=dict)
    vendor: dict = field(default_factory=dict)       # item -> copper cost to buy from a vendor
    vendor_sell: dict = field(default_factory=dict)  # item -> copper a vendor pays for it
    recipes: list = field(default_factory=list)
    refined: dict = field(default_factory=dict)      # refined item (bolt, bar) -> (raw item it is made from, raw per piece)

    def name(self, item_id):
        return self.items.get(item_id, f"Item {item_id}")


@dataclass
class ScanData:
    scans: dict = field(default_factory=dict)
    characters: dict = field(default_factory=dict)

    @property
    def realms(self):
        return sorted(self.scans)


def load_reference(path=None, extra=None, include_generated=True):
    """Load reference JSON. `extra` (a second file) overrides/extends the base."""
    merged = Reference()
    base = Path(path or DEFAULT_REFERENCE)
    generated = base.with_name("wowhead.json")  # produced by the Wowhead updater; overrides seed data
    for p in (path or DEFAULT_REFERENCE, generated if include_generated and generated.is_file() else None, extra):
        if p is DEFAULT_REFERENCE and not Path(p).is_file():
            raise FileNotFoundError(f"reference data not found at {p}; set SHUFFLEDETECTOR_DATA")
        if not p:
            continue
        with open(p, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
        merged.items.update({int(k): v for k, v in raw.get("items", {}).items()})
        merged.vendor.update({int(k): int(v) for k, v in raw.get("vendor", {}).items()})
        merged.vendor_sell.update({int(k): int(v) for k, v in raw.get("vendor_sell", {}).items()})
        for k, v in raw.get("refined", {}).items():
            merged.refined[int(k)] = (int(v["raw"]), int(v["qty"]))
        by_name = {r["name"].lower(): r for r in merged.recipes}
        for r in raw.get("recipes", []):
            by_name[r["name"].lower()] = r
        merged.recipes = list(by_name.values())
    return merged


def load_scan_data(path):
    raw = luaparse.load(path)
    db = raw.get(SAVED_VARIABLES_NAME)
    if not isinstance(db, dict):
        raise ValueError(f"{SAVED_VARIABLES_NAME} not found in {path}")
    scans = {}
    for realm, scan in (db.get("scans") or {}).items():
        items = {}
        shallow = bool(scan.get("shallow"))
        for item_id, e in (scan.get("items") or {}).items():
            prices = [(int(p[0]), int(p[1])) for p in e.get("prices", [])]
            qty = int(e["qty"])
            if shallow:
                # min price only (e.g. Auctionator): assume any quantity is buyable at that price
                qty = UNLIMITED_QTY
                prices = [(int(e["min"]), UNLIMITED_QTY)]
            items[int(item_id)] = {"min": int(e["min"]), "qty": qty, "prices": prices}
        scans[realm] = {
            "time": scan.get("time"),
            "listings": scan.get("listings", 0),
            "items": items,
            "source": scan.get("source") or "scan",
            "shallow": shallow,
        }
    return ScanData(scans=scans, characters=db.get("characters") or {})


def candidate_saved_variables(extra_roots=()):
    """Best-effort discovery of the addon's SavedVariables files (newest first)."""
    found = []
    for inst in addon_manager.discover_installs(extra_roots):
        flavor_dir = inst.addons_dir.parent.parent
        found += flavor_dir.glob(f"WTF/Account/*/SavedVariables/{ADDON_FILE}")
    return sorted(found, key=lambda p: p.stat().st_mtime, reverse=True)