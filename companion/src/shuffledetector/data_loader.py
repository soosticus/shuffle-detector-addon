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

    def with_local(self, recipes):
        """Copy with recipes read from the local game install layered over the bundled ones.

        The client's reagents, product and trivial levels replace the bundled recipe of the same name,
        which keeps its yields, source and skill; recipes the bundle lacks are added.
        """
        out = Reference(items=dict(self.items), vendor=dict(self.vendor), vendor_sell=dict(self.vendor_sell),
                        recipes=[], refined=dict(self.refined))
        by_name = {r["name"].lower(): r for r in self.recipes}
        for r in recipes:
            by_name[r["name"].lower()] = {**(by_name.get(r["name"].lower()) or {"yields": [], "source": "Game client"}), **r}
        out.recipes = list(by_name.values())
        return out

    def with_observed(self, scan):
        """Copy of this reference with what the addon recorded in game layered on top.

        Item names and vendor sell prices from the game replace the bundled ones. Recipes the
        characters know (with the reagents and pieces made as the game reports them) replace the
        bundled recipe of the same name, keeping its skill, yields and source; unknown recipes are added.
        """
        out = Reference(items=dict(self.items), vendor=dict(self.vendor), vendor_sell=dict(self.vendor_sell),
                        recipes=[], refined=dict(self.refined))
        for item_id, e in scan.items.items():
            if e.get("name"):
                out.items[item_id] = e["name"]
            if e.get("sell"):
                out.vendor_sell[item_id] = e["sell"]
        out.vendor.update(scan.vendor)
        by_name = {r["name"].lower(): r for r in self.recipes}
        for r in observed_recipes(scan.characters):
            merged = dict(by_name.get(r["name"].lower()) or {"yields": [], "source": "Recorded in game"})
            merged.update(r)
            by_name[r["name"].lower()] = merged
        yields_by_item = observed_yields(scan.disenchants)
        final = {}
        for name, recipe in by_name.items():
            obs = yields_by_item.get(recipe.get("item"))
            if obs:
                recipe = dict(recipe)
                recipe["yields"] = obs["yields"]
                recipe["yield_samples"] = obs["samples"]
            final[name] = recipe
        out.recipes = list(final.values())
        for item_id, entry in derive_refined(out.recipes).items():
            out.refined.setdefault(item_id, entry)
        return out


@dataclass
class ScanData:
    scans: dict = field(default_factory=dict)
    characters: dict = field(default_factory=dict)
    items: dict = field(default_factory=dict)        # item id -> {"name", "sell"} as recorded in game
    vendor: dict = field(default_factory=dict)       # item id -> copper to buy one from a vendor, as seen in game
    disenchants: list = field(default_factory=list)  # [{"item", "quality", "ilvl", "loot": [{"item","qty"}], "time"}, ...]

    @property
    def realms(self):
        return sorted(self.scans)


def load_reference(path=None, extra=None):
    """Load reference JSON. `extra` (a second file) overrides/extends the base."""
    merged = Reference()
    base = Path(path or DEFAULT_REFERENCE)
    for p in (path or DEFAULT_REFERENCE, extra):
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
    items = {}
    for item_id, e in (db.get("items") or {}).items():
        if isinstance(e, dict):
            items[int(item_id)] = {"name": e.get("name"), "sell": int(e.get("sell") or 0)}
    vendor = {int(k): int(v) for k, v in (db.get("vendor") or {}).items() if isinstance(v, (int, float))}
    disenchants = []
    for d in _as_list(db.get("disenchants")):
        if not isinstance(d, dict) or not d.get("item"):
            continue
        loot = [{"item": int(x["item"]), "qty": int(x.get("qty") or 1)}
                for x in _as_list(d.get("loot")) if isinstance(x, dict) and x.get("item")]
        disenchants.append({"item": int(d["item"]), "quality": d.get("quality"), "ilvl": d.get("ilvl"),
                            "loot": loot, "time": d.get("time")})
    return ScanData(scans=scans, characters=db.get("characters") or {}, items=items, vendor=vendor,
                    disenchants=disenchants)


def _as_list(value):
    """A Lua array parsed as a list, or an index-keyed table parsed as a dict."""
    if isinstance(value, dict):
        return [value[k] for k in sorted(value, key=lambda k: (not isinstance(k, int), k))]
    return value or []


def observed_recipes(characters):
    """Recipes in the characters' saved profession data that carry reagents, as reference recipes.

    Learned recipes come first; recipes the profession window listed but the character has not
    learned ("available") fill in names no character knows, with the game's trivial level and source text.
    """
    found = {}
    for key in ("recipes", "available"):
        for c in characters.values():
            for pname, prof in (c.get("professions") or {}).items():
                for r in _as_list(prof.get(key)):
                    reagents = [{"item": int(x["item"]), "qty": int(x.get("qty") or 1)}
                                for x in _as_list(r.get("reagents")) if isinstance(x, dict) and x.get("item")]
                    if not (r.get("name") and reagents):
                        continue
                    recipe = {"name": r["name"], "profession": pname, "reagents": reagents}
                    if r.get("item"):
                        recipe["item"] = int(r["item"])
                    if r.get("spell"):
                        recipe["spell"] = int(r["spell"])
                    if (r.get("makes") or 1) > 1:
                        recipe["makes"] = int(r["makes"])
                    if key == "available":
                        if r.get("trivial"):
                            recipe["trivial"] = int(r["trivial"])
                        if r.get("source"):
                            recipe["source"] = str(r["source"])
                    found.setdefault(r["name"].lower(), recipe)
    return list(found.values())


def observed_yields(disenchants):
    """Average disenchant loot observed in game, by the disenchanted item id.

    item id -> {"yields": [{"item", "avg"}, ...], "samples": number of disenchants of that item}
    """
    totals = {}
    for d in disenchants or []:
        item = d.get("item")
        if not item:
            continue
        bucket = totals.setdefault(item, {"count": 0, "loot": {}})
        bucket["count"] += 1
        for x in d.get("loot") or []:
            bucket["loot"][x["item"]] = bucket["loot"].get(x["item"], 0) + x.get("qty", 1)
    return {
        item: {
            "yields": [{"item": loot_item, "avg": qty / bucket["count"]}
                      for loot_item, qty in sorted(bucket["loot"].items())],
            "samples": bucket["count"],
        }
        for item, bucket in totals.items()
    }


def derive_refined(recipes):
    """Single-input intermediates (bolts, bars) that other recipes use as a reagent: item -> (raw item, raw per piece)."""
    used = {x["item"] for r in recipes for x in r["reagents"]}
    refined = {}
    for r in recipes:
        item = r.get("item")
        if item in used and len(r["reagents"]) == 1 and r["reagents"][0]["item"] != item:
            raw = r["reagents"][0]
            per, rem = divmod(raw["qty"], r.get("makes") or 1)
            if per and not rem:
                refined.setdefault(item, (raw["item"], per))
    return refined


def candidate_saved_variables(extra_roots=()):
    """Best-effort discovery of the addon's SavedVariables files (newest first)."""
    found = []
    for inst in addon_manager.discover_installs(extra_roots):
        flavor_dir = inst.addons_dir.parent.parent
        found += flavor_dir.glob(f"WTF/Account/*/SavedVariables/{ADDON_FILE}")
    return sorted(found, key=lambda p: p.stat().st_mtime, reverse=True)