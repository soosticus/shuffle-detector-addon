"""Tests for the SavedVariables parser, pricing and ranking."""

from shuffledetector import calc, data_loader, luaparse

SAMPLE = '''
AHSnapshotDB = {
	["version"] = 1,
	["scans"] = {
		["Realm-Alliance"] = {
			["time"] = 1700000000,
			["listings"] = 9,
			["items"] = {
				[2997] = {
					["min"] = 100,
					["qty"] = 10,
					["prices"] = {
						{ 100, 2 }, -- [1]
						{ 150, 8 }, -- [2]
					},
				},
				[2321] = { ["min"] = 50, ["qty"] = 100, ["prices"] = { { 50, 100 } } },
				[10940] = { ["min"] = 400, ["qty"] = 5, ["prices"] = { { 400, 5 } } },
				[10938] = { ["min"] = 800, ["qty"] = 5, ["prices"] = { { 800, 5 } } },
				[10978] = { ["min"] = 1000, ["qty"] = 1, ["prices"] = { { 1000, 1 } } },
			},
		},
	},
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


def test_shallow_scan_is_unlimited_at_min_price(tmp_path):
    p = tmp_path / "ShuffleDetector.lua"
    p.write_text(
        'AHSnapshotDB = { scans = { ["R-A"] = { time = 1, listings = 1, source = "auctionator", shallow = true,'
        ' items = { [1234] = { min = 50, qty = 0, prices = { { 50, 1 } } } } } } }'
    )
    scan = data_loader.load_scan_data(p)
    s = scan.scans["R-A"]
    assert s["shallow"] and s["source"] == "auctionator"
    assert calc.buy_cost(s["items"][1234], 200) == 200 * 50


def test_rank_end_to_end(tmp_path):
    path = tmp_path / "ShuffleDetector.lua"
    path.write_text(SAMPLE, encoding="utf-8")
    scan = data_loader.load_scan_data(path)
    ref = data_loader.load_reference(include_generated=False)
    results = calc.rank(scan, ref, calc.Settings(price_mode="min"))
    vest = next(r for r in results if r.name == "Green Woolen Vest")
    # 4 bolts: 2@100 + 2@150 = 500; 2 fine thread: vendor 100*2 = 200 vs AH 100 -> AH
    assert vest.cost == 600
    gross = 0.9 * 400 + 0.4 * 800 + 0.1 * 1000
    assert round(vest.net, 6) == round(gross * 0.95, 6)
    assert vest.status == "known"
    assert results[-1].profit is None  # recipes with no scanned prices sort last
    assert vest in results[: results.index(results[-1]) + 1]

from shuffledetector import wowhead


def test_wowhead_parsing():
    html = (
        "id: 'disenchanting',\n    data: [{\"id\":10940,\"name\":\"Strange Dust\",\"count\":50,\"outof\":100,"
        "\"pctstack\":\"{1: 50,2: 50}\"}],\n});"
    )
    (y,) = wowhead.parse_disenchant(html)
    assert y["item"] == 10940 and y["n"] == 100
    assert abs(y["avg"] - 0.5 * 1.5) < 1e-9
    vendor = "id: 'sold-by',\n data: [{\"stock\":-1,\"cost\":[[9]],\"stack\":1}],\n});"
    assert wowhead.parse_vendor_price(vendor) == 9
    js = '[{"name":"A, b: c","quality":2,popularity:5}]'
    assert wowhead._loads_js(js) == [{"name": "A, b: c", "quality": 2, "popularity": 5}]


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
