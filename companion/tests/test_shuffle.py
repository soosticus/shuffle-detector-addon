"""Tests for the SavedVariables parser, pricing and ranking."""

from auctionator_fixture import entry, write

from shuffledetector import calc, data_loader, luaparse

SAMPLE = '''
AHSnapshotDB = {
	["version"] = 1,
	["characters"] = {
		["Bob-Realm-Alliance"] = {
			["professions"] = {
				["Tailoring"] = {
					["skill"] = 150,
					["max"] = 300,
					["recipes"] = { { ["name"] = "Green Woolen Vest", ["difficulty"] = "optimal" } },
				},
			},
		},
	},
}
'''


def test_parse_types_and_strings():
    out = luaparse.parse('X = { 1, 2, ["a\\"b"] = true, c = -1.5, [7] = "x\\ny" }')
    assert out["X"] == {1: 1, 2: 2, 'a"b': True, "c": -1.5, 7: "x\ny"}


def test_parse_array_and_comments():
    assert luaparse.parse("T = { 1, -- c\n 2, 3 }")["T"] == [1, 2, 3]


def test_buy_cost_walks_ladder():
    entry = {"min": 100, "qty": 10, "prices": [(100, 2), (150, 8)]}
    assert calc.buy_cost(entry, 4) == 2 * 100 + 2 * 150
    assert calc.buy_cost(entry, 11) is None


def test_sell_price_modes():
    entry = {"min": 100, "qty": 10, "prices": [(100, 2), (150, 8)]}
    assert calc.sell_price(entry, calc.Settings(price_mode="min")) == 100
    assert calc.sell_price(entry, calc.Settings(price_mode="avg_low")) == (200 + 450) / 5


def test_rank_end_to_end(tmp_path):
    path = tmp_path / "ShuffleDetector.lua"
    path.write_text(SAMPLE, encoding="utf-8")
    write(tmp_path, {"Realm": {str(i): entry(p, 2474) for i, p in
                               {2997: 100, 2321: 50, 10940: 400, 10938: 800, 10978: 1000}.items()}})
    scan = data_loader.load_scan_data(path)
    ref = data_loader.load_reference()
    results = calc.rank(scan, ref, calc.Settings(price_mode="min"))
    vest = next(r for r in results if r.name == "Green Woolen Vest")
    # 4 bolts at the 100 minimum = 400; 2 fine thread: vendor 100*2 = 200 vs AH 50*2 = 100 -> AH
    assert vest.cost == 500
    gross = 0.9 * 400 + 0.4 * 800 + 0.1 * 1000
    assert round(vest.net, 6) == round(gross * 0.95, 6)
    assert vest.status == "known"
    assert results[-1].profit is None  # recipes with no scanned prices sort last
    assert vest in results[: results.index(results[-1]) + 1]

def _exit_result(ah, vendor, de_price):
    items = {
        1: {"min": 10, "qty": 99, "prices": [[10, 99]]},                 # reagent
        2: {"min": de_price, "qty": 99, "prices": [[de_price, 99]]},     # disenchant output
    }
    if ah:
        items[3] = {"min": ah, "qty": 9, "prices": [[ah, 9]]}            # crafted item
    ref = data_loader.Reference(items={1: "R", 2: "Dust", 3: "Robe"}, vendor_sell={3: vendor} if vendor else {})
    recipe = {"name": "Robe", "item": 3, "skill": 1, "reagents": [{"item": 1, "qty": 2}], "yields": [{"item": 2, "avg": 1.0}]}
    return calc.evaluate(recipe, items, ref, calc.Settings(ah_cut=0.0, price_mode="min"))


def test_exit_picks_best_of_disenchant_ah_vendor():
    assert _exit_result(ah=500, vendor=50, de_price=100).exit == "Sell on AH"
    assert _exit_result(ah=None, vendor=300, de_price=100).exit == "Vendor"
    r = _exit_result(ah=50, vendor=20, de_price=100)
    assert r.exit == "Disenchant" and r.profit == 80


def test_exit_filter_excludes_resale():
    items = {1: {"min": 10, "qty": 99, "prices": [[10, 99]]}, 2: {"min": 100, "qty": 99, "prices": [[100, 99]]},
             3: {"min": 500, "qty": 9, "prices": [[500, 9]]}}
    ref = data_loader.Reference(items={1: "R", 2: "Dust", 3: "Robe"}, vendor_sell={3: 50})
    recipe = {"name": "Robe", "item": 3, "skill": 1, "reagents": [{"item": 1, "qty": 2}], "yields": [{"item": 2, "avg": 1.0}]}
    s = calc.Settings(ah_cut=0.0, price_mode="min", exits=("Disenchant",))
    r = calc.evaluate(recipe, items, ref, s)
    assert r.exit == "Disenchant" and r.profit == 80
    r = calc.evaluate(recipe, items, ref, calc.Settings(ah_cut=0.0, price_mode="min", exits=()))
    assert r.profit is None and r.exit == "-"
