"""Tests for the shuffle quantity calculator."""

import math

from shuffledetector import calc, calculator
from shuffledetector.data_loader import Reference

ENTRY_CLOTH = {"min": 100, "qty": 10, "prices": [(100, 2), (150, 8)]}
RECIPE = {
    "name": "Test Vest", "item": 1, "skill": 10,
    "reagents": [{"item": 2, "qty": 3}, {"item": 3, "qty": 1}],
    "yields": [{"item": 4, "avg": 0.5}, {"item": 5, "avg": 0.25}],
}


def make(items=None, vendor=None):
    ref = Reference(items={1: "Vest", 2: "Cloth", 3: "Thread", 4: "Dust", 5: "Essence"},
                    vendor=vendor if vendor is not None else {3: 40}, recipes=[RECIPE])
    items = items or {
        2: ENTRY_CLOTH,
        4: {"min": 200, "qty": 50, "prices": [(200, 50)]},
        5: {"min": 1000, "qty": 50, "prices": [(1000, 50)]},
    }
    settings = calc.Settings(price_mode="min", exits=("Disenchant",))
    return ref, items, settings, calc.evaluate(RECIPE, items, ref, settings)


def test_buy_mix_walks_ah_then_vendor():
    entry = {"min": 100, "qty": 4, "prices": [(100, 2), (150, 2)]}
    assert calculator.buy_mix(entry, 120, 3) == (2, 200, 1, 120, 0)
    assert calculator.buy_mix(entry, None, 6) == (4, 500, 0, 0.0, 2)
    assert calculator.buy_mix(None, 40, 5) == (0, 0.0, 5, 200, 0)
    assert calculator.buy_mix(None, None, 2) == (0, 0.0, 0, 0.0, 2)


def test_buy_mix_prices_unlisted_depth_at_last_price():
    entry = {"min": 100, "qty": 10, "prices": [(100, 2), (150, 3)]}
    ah_qty, ah_cost, *_ = calculator.buy_mix(entry, None, 10)
    assert ah_qty == 10 and ah_cost == 2 * 100 + 3 * 150 + 5 * 150


def test_crafts_target_shopping_list_and_totals():
    ref, items, settings, res = make()
    b = calculator.calculate(res, items, ref, settings, crafts=3)
    assert b.crafts == 3 and b.limited_by == ""
    cloth, thread = b.purchases
    assert cloth.qty == 9 and cloth.ah_qty == 9
    assert cloth.ah_cost == 2 * 100 + 7 * 150
    assert thread.qty == 3 and thread.vendor_qty == 3 and thread.vendor_cost == 120
    assert b.cost == cloth.total + thread.total
    assert [o.expected for o in b.outputs] == [1.5, 0.75]
    per_craft_net = (0.5 * 200 + 0.25 * 1000) * 0.95
    assert math.isclose(b.revenue, per_craft_net * 3)
    assert math.isclose(b.profit, b.revenue - b.cost)
    assert b.profit_low < b.profit < b.profit_high


def test_range_widens_with_batch_size_but_shrinks_relatively():
    ref, items, settings, res = make({
        2: {"min": 1, "qty": 10**9, "prices": [(1, 10**9)]},
        4: {"min": 200, "qty": 50, "prices": [(200, 50)]},
        5: {"min": 1000, "qty": 50, "prices": [(1000, 50)]},
    })
    small = calculator.calculate(res, items, ref, settings, crafts=4)
    large = calculator.calculate(res, items, ref, settings, crafts=400)
    assert large.revenue_high - large.revenue_low > small.revenue_high - small.revenue_low
    assert (large.revenue_high - large.revenue_low) / large.revenue < (small.revenue_high - small.revenue_low) / small.revenue


def test_crafts_capped_by_availability():
    ref, items, settings, res = make()
    b = calculator.calculate(res, items, ref, settings, crafts=10)
    assert b.crafts == 3 and b.limited_by == "availability"  # 10 cloth listed, 3 per craft
    assert any("Only 3 of the 10" in n for n in b.notes)


def test_budget_target_buys_as_many_as_affordable():
    ref, items, settings, res = make()
    one = calculator.calculate(res, items, ref, settings, crafts=1).cost
    two = calculator.calculate(res, items, ref, settings, crafts=2).cost
    b = calculator.calculate(res, items, ref, settings, budget=two)
    assert b.crafts == 2 and b.limited_by == "budget"
    b = calculator.calculate(res, items, ref, settings, budget=two - 1)
    assert b.crafts == 1 and b.cost <= two - 1
    b = calculator.calculate(res, items, ref, settings, budget=one - 1)
    assert b.crafts == 0 and b.profit is None and b.notes


def test_budget_limited_by_availability():
    ref, items, settings, res = make()
    b = calculator.calculate(res, items, ref, settings, budget=10**9)
    assert b.crafts == 3 and b.limited_by == "availability"


def test_vendor_only_budget_is_capped():
    ref, items, settings, _ = make(items={4: {"min": 200, "qty": 50, "prices": [(200, 50)]}},
                                   vendor={2: 5, 3: 5})
    res = calc.evaluate(RECIPE, items, ref, settings)
    b = calculator.calculate(res, items, ref, settings, budget=10**12)
    assert b.crafts == calculator.MAX_CRAFTS and b.limited_by == "cap"


def test_sell_exit_has_no_range():
    ref, items, _, _ = make()
    items = {**items, 1: {"min": 5000, "qty": 3, "prices": [(5000, 3)]}}
    settings = calc.Settings(price_mode="min", exits=("Sell on AH",))
    res = calc.evaluate(RECIPE, items, ref, settings)
    b = calculator.calculate(res, items, ref, settings, crafts=2)
    assert b.exit == "Sell on AH"
    assert b.revenue == b.revenue_low == b.revenue_high == 2 * 5000 * 0.95
    assert b.outputs[0].name == "Vest" and b.outputs[0].expected == 2


def test_requires_exactly_one_target():
    ref, items, settings, res = make()
    for kw in ({}, {"crafts": 1, "budget": 5}):
        try:
            calculator.calculate(res, items, ref, settings, **kw)
        except ValueError:
            continue
        raise AssertionError("expected ValueError")


def test_format_batch_mentions_key_figures():
    ref, items, settings, res = make()
    text = calculator.format_batch(calculator.calculate(res, items, ref, settings, crafts=3))
    for needle in ("Test Vest: 3 crafts", "9 x Cloth", "Total cost", "Dust", "Profit"):
        assert needle in text


def test_parse_money():
    assert calculator.parse_money("5000") == 5000
    assert calculator.parse_money("50g") == 500000
    assert calculator.parse_money("1g 20s 5c") == 12005
    assert calculator.parse_money("2.5g") == 25000
    for bad in ("", "g", "5x", "1g2"):
        try:
            calculator.parse_money(bad)
        except ValueError:
            continue
        raise AssertionError(bad)


BOLT_RECIPE = {
    "name": "Bolt Vest", "item": 1, "skill": 10,
    "reagents": [{"item": 2, "qty": 3}],
    "yields": [{"item": 4, "avg": 1.0}],
}


def bolt_setup(bolt_price, cloth_price, bolt_qty=100, cloth_qty=100):
    ref = Reference(items={1: "Vest", 2: "Bolt", 3: "Cloth", 4: "Dust"}, refined={2: (3, 2)}, recipes=[BOLT_RECIPE])
    items = {
        2: {"min": bolt_price, "qty": bolt_qty, "prices": [(bolt_price, bolt_qty)]},
        3: {"min": cloth_price, "qty": cloth_qty, "prices": [(cloth_price, cloth_qty)]},
        4: {"min": 1000, "qty": 100, "prices": [(1000, 100)]},
    }
    settings = calc.Settings(price_mode="min", exits=("Disenchant",))
    return ref, items, settings


def test_evaluate_picks_cheaper_of_bolt_or_raw_cloth():
    ref, items, settings = bolt_setup(bolt_price=300, cloth_price=100)  # a bolt costs 200 from 2 cloth
    line = calc.evaluate(BOLT_RECIPE, items, ref, settings).reagents[0]
    assert line.source == "Craft from Cloth" and line.total == 3 * 200 and line.raw_unit == 200 and line.ah_unit == 300
    ref, items, settings = bolt_setup(bolt_price=150, cloth_price=100)
    line = calc.evaluate(BOLT_RECIPE, items, ref, settings).reagents[0]
    assert line.source == "AH" and line.total == 3 * 150 and line.raw_unit == 200


def test_evaluate_uses_raw_cloth_when_bolts_unlisted():
    ref, items, settings = bolt_setup(300, 100)
    del items[2]
    res = calc.evaluate(BOLT_RECIPE, items, ref, settings)
    assert res.cost == 600 and res.reagents[0].raw_item == 3 and res.reagents[0].raw_qty == 2


def test_shopping_list_mixes_bolts_and_raw_cloth():
    # 5 cheap bolts are listed; the rest are cheaper to make from cloth (2 x 100 = 200 < 300).
    ref, items, settings = bolt_setup(300, 100)
    items[2] = {"min": 100, "qty": 10, "prices": [(100, 5), (300, 5)]}
    res = calc.evaluate(BOLT_RECIPE, items, ref, settings)
    b = calculator.calculate(res, items, ref, settings, crafts=3)  # 9 bolts needed
    bolt, cloth = b.purchases
    assert bolt.item == 2 and bolt.qty == 5 and bolt.ah_cost == 500
    assert cloth.item == 3 and cloth.qty == 8 and cloth.ah_cost == 800 and cloth.note == "makes 4 x Bolt"
    assert b.cost == 1300


def test_shopping_list_all_raw_cloth_and_availability():
    ref, items, settings = bolt_setup(1000, 100, cloth_qty=12)
    res = calc.evaluate(BOLT_RECIPE, items, ref, settings)
    plan = calculator.shopping_list(BOLT_RECIPE, items, ref, 1)  # 3 bolts: cloth 6 of 12
    assert [p.item for p in plan] == [3] and plan[0].qty == 6 and plan[0].short == 0
    b = calculator.calculate(res, items, ref, settings, budget=10**9)
    assert b.crafts > 0 and all(p.short == 0 for p in b.purchases)


def test_time_counts_craft_and_disenchant_per_piece():
    ref, items, settings, res = make()
    settings.craft_seconds, settings.disenchant_seconds = 30, 3
    res = calc.evaluate(RECIPE, items, ref, settings)
    assert res.exit == "Disenchant" and res.seconds == 33
    b = calculator.calculate(res, items, ref, settings, crafts=3)
    assert b.crafts == 3 and b.seconds == 99
    assert b.profit_per_hour == b.profit / 99 * 3600
    assert "Expected time: 1m 39s" in calculator.format_batch(b)


def test_time_has_no_disenchant_for_sell_exit_and_recipe_override():
    ref, items, settings, _ = make()
    settings.exits = ("Sell on AH",)
    items = dict(items)
    items[1] = {"min": 5000, "qty": 5, "prices": [(5000, 5)]}
    recipe = dict(RECIPE, craft_seconds=10)
    res = calc.evaluate(recipe, items, ref, settings)
    assert res.exit == "Sell on AH" and res.seconds == 10


def test_fmt_duration():
    assert calc.fmt_duration(45) == "45s"
    assert calc.fmt_duration(750) == "12m 30s"
    assert calc.fmt_duration(3900) == "1h 5m"


POTION = {
    "name": "Test Potion", "profession": "Alchemy", "item": 1, "skill": 50, "makes": 2,
    "reagents": [{"item": 2, "qty": 1}], "yields": [],
}


def potion_setup():
    ref = Reference(items={1: "Potion", 2: "Herb"}, vendor_sell={1: 40}, recipes=[POTION, RECIPE])
    items = {2: {"min": 100, "qty": 50, "prices": [(100, 50)]}, 1: {"min": 300, "qty": 20, "prices": [(300, 20)]}}
    return ref, items, calc.Settings(price_mode="min", ah_cut=0.0, exits=("Disenchant", "Sell on AH", "Vendor"))


def test_makes_multiplies_output_and_skips_disenchant_without_yields():
    ref, items, settings = potion_setup()
    res = calc.evaluate(POTION, items, ref, settings)
    assert res.profession == "Alchemy" and res.crafted.qty == 2
    assert [e.label for e in res.exits] == ["Sell on AH", "Vendor"]
    assert res.exit == "Sell on AH" and res.net == 600 and res.profit == 500 and res.seconds == 30
    b = calculator.calculate(res, items, ref, settings, crafts=3)
    assert b.crafts == 3 and b.cost == 300


def test_rank_uses_each_recipes_own_profession_skill_and_filter():
    ref, items, settings = potion_setup()
    from shuffledetector.data_loader import ScanData
    scan = ScanData(scans={"R": {"items": items, "listings": 1, "shallow": False}},
                    characters={"Me": {"professions": {
                        "Alchemy": {"skill": 60, "recipes": [{"name": "Test Potion"}]},
                        "Tailoring": {"skill": 5, "recipes": []}}}})
    by_name = {r.name: r for r in calc.rank(scan, ref, settings, "R")}
    assert by_name["Test Potion"].status == "known" and by_name["Test Vest"].status == "needs_skill"
    only = calc.rank(scan, ref, settings, "R", professions=["alchemy"])
    assert [r.name for r in only] == ["Test Potion"]


def test_parse_costs_names_ids_and_problems():
    ref, *_ = make()
    costs, problems = calculator.parse_costs(["Cloth = 1g 20s", " thread=50 ", "5 = 2s", "# note", "", "Nope = 1g", "Cloth", "Dust = x"], ref)
    assert costs == {2: 12000, 3: 50, 5: 200}
    assert len(problems) == 3 and "Nope" in problems[0]


def test_custom_cost_replaces_market_price_for_any_quantity():
    ref, items, settings, res = make()
    b = calculator.calculate(res, items, ref, settings, crafts=1000, costs={2: 90})
    cloth, thread = b.purchases
    assert b.limited_by == ""  # the AH only lists 10 cloth, but a custom cost has no stock limit
    assert cloth.custom_qty == 3000 and cloth.custom_cost == 270000 and cloth.ah_qty == 0 and cloth.short == 0
    assert cloth.total == 270000 and cloth.unit == 90
    assert thread.vendor_qty == 1000  # untouched materials keep their market prices
    assert any("Your own average cost" in n for n in b.notes)
    assert "3000 at your cost" in calculator.format_batch(b)


def test_custom_cost_works_with_budget_and_flags_unused_items():
    ref, items, settings, res = make()
    b = calculator.calculate(res, items, ref, settings, budget=10_000, costs={2: 100, 3: 100, 4: 5})
    assert b.limited_by == "budget" and b.crafts == 10_000 // 400 and b.cost <= 10_000
    assert any("ignored" in n and "Dust" in n for n in b.notes)


def test_custom_cost_for_bolt_or_its_cloth():
    ref = Reference(items={1: "Robe", 6: "Bolt", 7: "Silk"}, vendor={}, refined={6: (7, 4)},
                    recipes=[{"name": "Robe", "item": 1, "reagents": [{"item": 6, "qty": 2}], "yields": []}])
    items = {6: {"min": 5000, "qty": 100, "prices": [(5000, 100)]}, 7: {"min": 100, "qty": 100, "prices": [(100, 100)]}}
    settings = calc.Settings(price_mode="min", exits=("Vendor",))
    recipe = ref.recipes[0]
    # silk at 300 each makes a bolt for 1200, cheaper than the 5000 bolt on the AH
    plan = calculator.shopping_list(recipe, items, ref, 1, {7: 300})
    silk = next(p for p in plan if p.item == 7)
    assert silk.custom_qty == 8 and silk.custom_cost == 2400
    # a custom bolt cost beats the market bolt and the market silk
    plan = calculator.shopping_list(recipe, items, ref, 1, {6: 50})
    assert [(p.item, p.custom_qty, p.custom_cost) for p in plan] == [(6, 2, 100)]
    # a custom bolt cost above the cost of making it is passed over, and the batch says so
    res = calc.evaluate(recipe, items, ref, settings)
    b = calculator.calculate(res, items, ref, settings, crafts=1, costs={6: 9000})
    assert not any(p.custom_qty for p in b.purchases)
    assert any("not used" in note and "Bolt" in note for note in b.notes)
