"""Tests for exporting a shuffle to the addon's Plan.lua."""

from shuffledetector import addon_manager as am, calc, data_loader, plan

from test_addon_manager import make_addon

RECIPE = {
    "name": 'Silk "Headband"', "item": 7054, "spell": 8774, "skill": 175,
    "reagents": [{"item": 4305, "qty": 4}, {"item": 4291, "qty": 2}],
    "yields": [{"item": 11083, "avg": 0.9}],
}


def result(exit_label="Disenchant"):
    ref = data_loader.Reference(items={7054: "Silk Headband"})
    res = calc.Result(recipe=RECIPE)
    res.crafted = calc.Line(7054, ref.name(7054), 1, None, None)
    res.exit = exit_label
    return res


def test_build_plan():
    p = plan.build_plan(result(), now=1700000000)
    assert p == {
        "version": 1, "generated": 1700000000, "recipe": 'Silk "Headband"', "exit": "Disenchant",
        "reagents": [{"item": 4305, "qty": 4}, {"item": 4291, "qty": 2}],
        "spell": 8774, "item": 7054, "itemName": "Silk Headband",
    }
    assert plan.build_plan(result("-"))["exit"] == ""


def test_render_plan_escapes_and_is_lua():
    text = plan.render_plan(plan.build_plan(result(), now=1))
    assert text.startswith("-- Written by") and "local _, ns = ..." in text
    assert 'recipe = "Silk \\"Headband\\"",' in text
    assert "reagents = { { item = 4305, qty = 4 }, { item = 4291, qty = 2 } }," in text
    assert plan.lua_string("a\\b\nc") == '"a\\\\b\\010c"'


def test_build_plan_preserves_output_quantity():
    res = result()
    res.recipe = dict(RECIPE, makes=3)
    assert plan.build_plan(res)["makes"] == 3
    assert "makes = 3," in plan.render_plan(plan.build_plan(res))

def test_build_plan_exports_finite_per_craft_estimates():
    res = result()
    res.cost, res.net = 123.5, 456.75
    assert plan.build_plan(res)["estimate"] == {"cost": 123.5, "income": 456.75}
    assert "estimate = { cost = 123.5, income = 456.75 }" in plan.render_plan(plan.build_plan(res))
    res.cost = float("nan")
    assert "estimate" not in plan.build_plan(res)
    res.cost, res.net = 100, float("inf")
    assert "estimate" not in plan.build_plan(res)


def test_build_plan_exports_raw_alternative_even_without_prices():
    res = result()
    res.reagents = [calc.Line(4305, "Bolt of Silk Cloth", 4, None, None,
                             raw_item=4306, raw_qty=4)]
    p = plan.build_plan(res)
    assert p["reagents"] == [
        {"item": 4305, "qty": 4, "raw": {"item": 4306, "qty": 4}},
        {"item": 4291, "qty": 2},
    ]
    assert "raw = { item = 4306, qty = 4 }" in plan.render_plan(p)


def test_evaluated_linen_plan_keeps_conversion_independent_of_cheapest_source():
    recipe = {"name": "Linen Bag", "item": 4238, "spell": 3755,
              "reagents": [{"item": 2996, "qty": 3}], "yields": []}
    ref = data_loader.Reference(items={2996: "Bolt of Linen Cloth", 2589: "Linen Cloth"},
                                refined={2996: (2589, 2)})
    items = {2996: {"qty": 100, "min": 10, "prices": [(10, 100)]},
             2589: {"qty": 100, "min": 20, "prices": [(20, 100)]}}
    res = calc.evaluate(recipe, items, ref, calc.Settings())
    assert res.reagents[0].source == "AH"
    assert plan.build_plan(res)["reagents"][0]["raw"] == {"item": 2589, "qty": 2}


def test_write_plan_and_survives_addon_update(tmp_path, monkeypatch):
    bundle = tmp_path / "bundle"
    make_addon(bundle, "0.3.0")
    monkeypatch.setenv("SHUFFLEDETECTOR_ADDON", str(bundle / am.ADDON_NAME))
    addons = tmp_path / "wow" / "_classic_" / "Interface" / "AddOns"
    addons.mkdir(parents=True)
    inst = am.Install("_classic_", addons)

    try:
        plan.write_plan(inst, plan.build_plan(result()))
        raise AssertionError("expected FileNotFoundError")
    except FileNotFoundError:
        pass

    am.install_addon(inst)
    path = plan.write_plan(inst, plan.build_plan(result(), now=5))
    assert path == inst.plan_file and "generated = 5," in path.read_text(encoding="utf-8")

    (inst.addon_dir / f"{am.ADDON_NAME}.toc").write_text("## Version: 0.2.0\n")
    am.install_addon(inst)
    assert "generated = 5," in inst.plan_file.read_text(encoding="utf-8")


def test_wanted_items_and_item_list():
    ref = data_loader.Reference(recipes=[RECIPE, {"name": "Bare", "reagents": [], "yields": []}],
                                refined={2997: (2996, 2)})
    assert plan.wanted_items(ref) == [2996, 2997, 4291, 4305, 7054, 11083]
    text = plan.render_item_list([1, 2, 3])
    assert "local _, ns = ..." in text and "ns.wantedItems = {\n    1, 2, 3,\n}" in text


def test_item_list_written_and_survives_addon_update(tmp_path, monkeypatch):
    bundle = tmp_path / "bundle"
    make_addon(bundle, "0.3.0")
    monkeypatch.setenv("SHUFFLEDETECTOR_ADDON", str(bundle / am.ADDON_NAME))
    addons = tmp_path / "wow" / "_classic_" / "Interface" / "AddOns"
    addons.mkdir(parents=True)
    inst = am.Install("_classic_", addons)
    am.install_addon(inst)
    path = plan.write_item_list(inst, [4305, 4291])
    assert path == inst.item_list_file and "4305, 4291," in path.read_text(encoding="utf-8")

    (inst.addon_dir / f"{am.ADDON_NAME}.toc").write_text("## Version: 0.2.0\n")
    am.install_addon(inst)
    assert "4305, 4291," in inst.item_list_file.read_text(encoding="utf-8")
