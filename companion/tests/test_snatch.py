"""Run the addon's shopping logic against a deterministic WoW API stub."""

import shutil
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest


@pytest.mark.parametrize("harness, marker", [
    ("snatch_harness.lua", "snatcher checks passed"),
    ("disenchant_harness.lua", "disenchant checks passed"),
    ("evaluate_harness.lua", "evaluate checks passed"),
    ("prices_harness.lua", "price provider checks passed"),
    ("planner_harness.lua", "planner workflow checks passed"),
])
def test_addon_lua_harness(harness, marker):
    lua = shutil.which("lua")
    if not lua:
        pytest.skip("Lua is required for the addon API harness")
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [lua, str(Path(__file__).with_name(harness))],
        cwd=root, capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert marker in result.stdout


def test_evaluator_python_lua_parity():
    """Keep valid companion economics while intentional DE corrections have Lua regressions."""
    from shuffledetector.calc import Settings, evaluate

    lua = shutil.which("lua")
    if not lua:
        pytest.skip("Lua is required for evaluator parity")
    recipe = {
        "name": "Synthetic", "item": 20, "makes": 1,
        "reagents": [{"item": 11, "qty": 3}],
        "yields": [{"item": 30, "avg": 1.25}, {"item": 31, "avg": 0.25}],
    }
    prices = {10: 10, 11: 50, 20: 40, 30: 100, 31: 20}
    items = {
        item: {"min": price, "qty": 1000, "prices": [(price, 1000)]}
        for item, price in prices.items()
    }
    ref = SimpleNamespace(
        vendor={11: 15}, vendor_sell={20: 50}, refined={11: (10, 2)},
        name=lambda item: f"Item {item}",
    )
    expected = evaluate(recipe, items, ref, Settings())
    script = """
local ns = {}
assert(loadfile("addon/ShuffleDetector/Evaluate.lua"))("ShuffleDetector", ns)
local prices = { [10]=10, [11]=50, [20]=40, [30]=100, [31]=20 }
local r = ns.Evaluate({
    name="Synthetic", item=20, makes=1, reagents={{item=11,qty=3}},
    disenchant={status="trusted",expected={[30]=1.25,[31]=0.25}},
}, {
    price=function(id) return prices[id] end,
    vendorBuy=function(id) if id==11 then return 15 end end,
    vendorSell=function(id) if id==20 then return 50 end end,
    refined={ [11]={raw=10,per=2} },
})
for _, key in ipairs({"cost","net","profit","roi","seconds","profitPerHour"}) do print(r[key]) end
print(r.exit)
"""
    result = subprocess.run(
        [lua, "-"], input=script, cwd=Path(__file__).resolve().parents[2],
        capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    lines = result.stdout.splitlines()
    actual = [float(value) for value in lines[:-1]]
    assert actual == pytest.approx([
        expected.cost, expected.net, expected.profit, expected.roi,
        expected.seconds, expected.profit_per_hour,
    ])
    assert lines[-1] == expected.exit
