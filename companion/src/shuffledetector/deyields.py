"""Expected disenchant yields from the player's own installed Auctionator addon.

Auctionator ships a table of disenchant results (Source_Classic/Enchant/DisenchantingProbabilities.lua) but
the game only loads it for the "classic" game type, not for the Forever client, so the addon cannot read it
in game. This reads that file from the AddOns folder next to the SavedVariables instead: nothing is
downloaded and no website is involved.
"""

import re
from pathlib import Path

TABLE_FILE = Path("Interface") / "AddOns" / "Auctionator" / "Source_Classic" / "Enchant" / "DisenchantingProbabilities.lua"
ITEM_CLASS = {"Weapon": 2, "Armor": 4}
ITEM_QUALITY = {"Good": 2, "Rare": 3, "Epic": 4}

_CLASS = re.compile(r"\[\s*Enum\.ItemClass\.(\w+)\s*\]")
_QUALITY = re.compile(r"\[\s*Enum\.ItemQuality\.(\w+)\s*\]")
_ENTRY = re.compile(r"^\{([\d\s.,]+)\}")


def parse_table(text):
    """{(item class id, quality id): [(low ilvl, high ilvl, [(percent, count, item id), ...]), ...]}"""
    table, cls, quality = {}, None, None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("--"):
            continue
        m = _CLASS.match(line)
        if m:
            cls = ITEM_CLASS.get(m.group(1))
            continue
        m = _QUALITY.match(line)
        if m:
            quality = ITEM_QUALITY.get(m.group(1))
            continue
        m = _ENTRY.match(line)
        if not (m and cls and quality):
            continue
        nums = [float(x) for x in m.group(1).replace(" ", "").split(",") if x]
        if len(nums) < 5 or (len(nums) - 2) % 3:
            continue
        triples = [(nums[i], nums[i + 1], int(nums[i + 2])) for i in range(2, len(nums), 3)]
        table.setdefault((cls, quality), []).append((nums[0], nums[1], triples))
    return table


def find_table_file(saved_variables_path):
    """Auctionator's table next to a SavedVariables file (<flavor>/WTF/Account/<acct>/SavedVariables/x.lua), or None."""
    parents = Path(saved_variables_path).resolve().parents
    if len(parents) > 5:
        candidate = parents[4] / TABLE_FILE
        if candidate.is_file():
            return candidate
    return None


def load_table(saved_variables_path):
    path = find_table_file(saved_variables_path)
    if not path:
        return {}
    try:
        return parse_table(path.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return {}


def expected_yields(table, item_class, quality, ilvl):
    """[{"item", "avg"}, ...] for one disenchant of an item of this class, quality and item level, or None."""
    for low, high, triples in table.get((item_class, quality), []):
        if low <= ilvl <= high:
            sums = {}
            for pct, count, item in triples:
                sums[item] = sums.get(item, 0.0) + pct / 100 * count
            out = [{"item": item, "avg": avg} for item, avg in sorted(sums.items()) if avg > 0]
            return out or None
    return None
