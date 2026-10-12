"""Recipe data read from the user's own WoW install (the client's DB2 tables).

Nothing is downloaded and nothing from the client is bundled: the tables are read from the local
Data folder at run time, so only the user's own copy of the game is involved. FileDataIDs are the
stable identifiers of the client files (see ROADMAP.md for how they were found).
"""

import json
import struct

from . import addon_manager
from .casc import Casc, CascError, find_install_root
from .db2 import Table

FDID_SKILL_LINE_ABILITY = 1266278
FDID_SPELL_NAME = 1990283
FDID_SPELL_EFFECT = 1140088
FDID_SPELL_REAGENTS = 841946
FDID_SPELL_MISC = 1003144
FDID_SPELL_CAST_TIMES = 1134089

# SkillLine id -> profession name as the game (and the addon's SavedVariables) spell it.
PROFESSIONS = {
    164: "Blacksmithing", 165: "Leatherworking", 171: "Alchemy", 185: "Cooking",
    197: "Tailoring", 202: "Engineering", 333: "Enchanting", 129: "First Aid",
}

EFFECT_CREATE_ITEM = 24
# Column positions inside each table (WDC5 layout of this client build).
_SLA_SKILL_LINE, _SLA_SPELL, _SLA_TRIVIAL_HIGH, _SLA_TRIVIAL_LOW = 3, 4, 9, 10
_EFFECT_EFFECT, _EFFECT_ITEM, _EFFECT_BASE_POINTS_F = 3, 10, 23
_MISC_CAST_TIME_INDEX = 2


def _float(bits):
    return struct.unpack("<f", struct.pack("<I", bits & 0xFFFFFFFF))[0]


def read_recipes(casc):
    """Crafting recipes of the known professions, in reference-recipe form."""
    sla = [r for r in Table(casc.read_fdid(FDID_SKILL_LINE_ABILITY)).rows()
           if r[1][_SLA_SKILL_LINE] in PROFESSIONS]
    spells = {r[1][_SLA_SPELL] for r in sla}

    products = {}
    for _rid, v, spell, _a in Table(casc.read_fdid(FDID_SPELL_EFFECT)).rows():
        if spell in spells and v[_EFFECT_EFFECT] == EFFECT_CREATE_ITEM and v[_EFFECT_ITEM]:
            makes = max(1, int(round(_float(v[_EFFECT_BASE_POINTS_F]))) + 1)
            products.setdefault(spell, (v[_EFFECT_ITEM], makes))

    reagents = {}
    for _rid, v, _fk, _a in Table(casc.read_fdid(FDID_SPELL_REAGENTS)).rows():
        if v[0] in spells:
            reagents[v[0]] = [{"item": i, "qty": q} for i, q in zip(v[1], v[2]) if i and q]

    cast_ms = {r[0]: r[1][0] for r in Table(casc.read_fdid(FDID_SPELL_CAST_TIMES)).rows()}
    cast_index = {}
    for _rid, v, spell, _a in Table(casc.read_fdid(FDID_SPELL_MISC)).rows():
        if spell in spells:
            cast_index.setdefault(spell, v[_MISC_CAST_TIME_INDEX])

    names = Table(casc.read_fdid(FDID_SPELL_NAME))
    name_of = {r[0]: names.string_at(r, 0) for r in names.rows() if r[0] in spells}

    out, seen = [], set()
    for _rid, v, _fk, _a in sla:
        spell = v[_SLA_SPELL]
        if spell in seen or spell not in products or not reagents.get(spell) or not name_of.get(spell):
            continue
        seen.add(spell)
        item, makes = products[spell]
        recipe = {
            "name": name_of[spell], "profession": PROFESSIONS[v[_SLA_SKILL_LINE]], "spell": spell,
            "item": item, "reagents": reagents[spell],
            "trivial": v[_SLA_TRIVIAL_HIGH], "yellow": v[_SLA_TRIVIAL_LOW],
        }
        if makes > 1:
            recipe["makes"] = makes
        ms = cast_ms.get(cast_index.get(spell))
        if ms:
            recipe["cast_ms"] = ms
        out.append(recipe)
    return out


def find_install(extra_roots=()):
    """First WoW install (folder holding .build.info and Data) among `extra_roots` and the usual places."""
    for hint in (*extra_roots, *addon_manager.default_roots()):
        root = find_install_root(hint) if hint else None
        if root:
            return root
    return None


def load_local_recipes(install_hint):
    """Recipes from the install containing `install_hint` (any path inside it), or None if unreadable."""
    root = find_install_root(install_hint)
    if root is None:
        return None
    casc = Casc(root)
    try:
        return {"build": casc.version, "recipes": read_recipes(casc)}
    except CascError:
        return None
    finally:
        casc.close()


def save_json(data, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1)
