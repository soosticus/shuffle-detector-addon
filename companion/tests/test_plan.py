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
