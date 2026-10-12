"""Tests for recipes read from the game's data tables (tables faked; the real reader needs an install)."""

import struct

from shuffledetector import localdata
from shuffledetector.data_loader import Reference


class FakeTable:
    def __init__(self, rows, strings=None):
        self._rows, self._strings = rows, strings or {}

    def rows(self):
        return self._rows

    def string_at(self, row, _i):
        return self._strings[row[0]]


def f(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


def effect(item, base_points=0.0, effect_id=24):
    v = [0] * 29
    v[3], v[10], v[23] = effect_id, item, f(base_points)
    return v


def sla(skill_line, spell, high, low):
    v = [0] * 16
    v[3], v[4], v[9], v[10] = skill_line, spell, high, low
    return v


class FakeCasc:
    def read_fdid(self, fdid):
        return fdid


def test_read_recipes(monkeypatch):
    tables = {
        localdata.FDID_SKILL_LINE_ABILITY: FakeTable([
            (1, sla(197, 2963, 50, 25), None, 0), (2, sla(197, 111, 5, 1), None, 0),
            (3, sla(9999, 222, 5, 1), None, 0), (4, sla(185, 333, 30, 10), None, 0)]),
        localdata.FDID_SPELL_EFFECT: FakeTable([
            (10, effect(2996), 2963, 0), (11, effect(0, effect_id=53), 111, 0),
            (12, effect(5525, 1.0), 333, 0), (13, effect(1), 222, 0)]),
        localdata.FDID_SPELL_REAGENTS: FakeTable([
            (2963, [2963, (2589, 0), (2, 0)], None, 0), (333, [333, (5503, 0), (1, 0)], None, 0)]),
        localdata.FDID_SPELL_CAST_TIMES: FakeTable([(14, [3000, 3000], None, 0)]),
        localdata.FDID_SPELL_MISC: FakeTable([(5, [0, 0, 14], 2963, 0)]),
        localdata.FDID_SPELL_NAME: FakeTable([(2963, [0], None, 0), (333, [0], None, 0)],
                                             {2963: "Bolt of Linen Cloth", 333: "Boiled Clams"}),
    }
    monkeypatch.setattr(localdata, "Table", lambda data: tables[data])
    recipes = {r["name"]: r for r in localdata.read_recipes(FakeCasc())}
    assert set(recipes) == {"Bolt of Linen Cloth", "Boiled Clams"}
    bolt = recipes["Bolt of Linen Cloth"]
    assert bolt == {"name": "Bolt of Linen Cloth", "profession": "Tailoring", "spell": 2963, "item": 2996,
                    "reagents": [{"item": 2589, "qty": 2}], "trivial": 50, "yellow": 25, "cast_ms": 3000}
    assert recipes["Boiled Clams"]["makes"] == 2 and recipes["Boiled Clams"]["profession"] == "Cooking"


def test_with_local_keeps_bundled_yields_and_adds_new():
    ref = Reference(recipes=[{"name": "Test Robe", "profession": "Tailoring", "reagents": [{"item": 1, "qty": 1}],
                              "yields": [{"item": 9, "avg": 1}], "skill": 50}])
    out = ref.with_local([{"name": "test robe", "reagents": [{"item": 2, "qty": 3}], "trivial": 80},
                          {"name": "New Thing", "reagents": [{"item": 4, "qty": 1}]}])
    by = {r["name"].lower(): r for r in out.recipes}
    assert by["test robe"]["reagents"] == [{"item": 2, "qty": 3}] and by["test robe"]["skill"] == 50
    assert by["test robe"]["yields"] == [{"item": 9, "avg": 1}] and by["test robe"]["trivial"] == 80
    assert by["new thing"]["yields"] == []
    assert len(ref.recipes) == 1
