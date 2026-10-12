"""Tests for data the addon records in game (recipes with reagents, item names and sell prices)."""

from shuffledetector import calc, data_loader
from shuffledetector.data_loader import Reference

LUA = """
AHSnapshotDB = {
  scans = {},
  items = {
    [2589] = { name = "Linen Cloth", sell = 13 },
    [2996] = { name = "Bolt of Linen Cloth", sell = 50 },
    [7054] = { name = "Test Robe", sell = 0 },
  },
  characters = {
    ["Me-Realm-Alliance"] = {
      professions = {
        Tailoring = { skill = 60, max = 75, recipes = {
          { name = "Bolt of Linen Cloth", item = 2996, spell = 2963, makes = 1,
            reagents = { { item = 2589, qty = 2 } } },
          { name = "Test Robe", item = 7054, spell = 1, reagents = { { item = 2996, qty = 3 }, { item = 2320, qty = 1 } } },
          { name = "Old Entry", spell = 9 },
        } },
        Cooking = { skill = 10, max = 75, recipes = {
          { name = "Boiled Clams", item = 5525, makes = 2, reagents = { { item = 5503, qty = 1 } } },
        } },
      },
    },
  },
}
"""


def load(tmp_path):
    p = tmp_path / "ShuffleDetector.lua"
    p.write_text(LUA)
    return data_loader.load_scan_data(str(p))


def test_loads_recorded_items(tmp_path):
    scan = load(tmp_path)
    assert scan.items[2589] == {"name": "Linen Cloth", "sell": 13}


def test_observed_recipes_need_reagents(tmp_path):
    names = {r["name"] for r in data_loader.observed_recipes(load(tmp_path).characters)}
    assert names == {"Bolt of Linen Cloth", "Test Robe", "Boiled Clams"}


def test_with_observed_adds_recipes_names_and_refined(tmp_path):
    scan = load(tmp_path)
    ref = Reference(items={2589: "Old name"}).with_observed(scan)
    assert ref.items[2589] == "Linen Cloth"
    assert ref.vendor_sell[2996] == 50 and 7054 not in ref.vendor_sell
    assert ref.refined[2996] == (2589, 2)
    clams = next(r for r in ref.recipes if r["name"] == "Boiled Clams")
    assert clams["profession"] == "Cooking" and clams["makes"] == 2 and clams["yields"] == []


def test_with_observed_keeps_seed_yields_and_skill(tmp_path):
    seed = {"name": "test robe", "skill": 40, "source": "Trainer", "yields": [{"item": 1, "avg": 1.0}],
            "reagents": [{"item": 9, "qty": 9}]}
    ref = Reference(recipes=[seed]).with_observed(load(tmp_path))
    robes = [r for r in ref.recipes if r["name"].lower() == "test robe"]
    assert len(robes) == 1
    assert robes[0]["skill"] == 40 and robes[0]["yields"] and robes[0]["source"] == "Trainer"
    assert robes[0]["reagents"][0] == {"item": 2996, "qty": 3}
    assert seed["reagents"][0]["item"] == 9


def test_refined_skips_fractional_ratios():
    recipes = [{"name": "Split", "item": 5, "makes": 3, "reagents": [{"item": 1, "qty": 1}]},
               {"name": "Use", "item": 9, "reagents": [{"item": 5, "qty": 1}, {"item": 2, "qty": 1}]}]
    assert data_loader.derive_refined(recipes) == {}


def test_recorded_recipe_ranks_as_known(tmp_path):
    scan = load(tmp_path)
    scan.scans["R"] = {"items": {2589: {"min": 10, "qty": 100, "prices": [(10, 100)]},
                                 5503: {"min": 5, "qty": 100, "prices": [(5, 100)]},
                                 5525: {"min": 100, "qty": 10, "prices": [(100, 10)]}}}
    ref = Reference().with_observed(scan)
    res = calc.rank(scan, ref, calc.Settings(price_mode="min", exits=("Sell on AH",)), "R", "Me-Realm-Alliance",
                    professions=["Cooking"])
    assert len(res) == 1 and res[0].status == "known" and res[0].profit > 0
