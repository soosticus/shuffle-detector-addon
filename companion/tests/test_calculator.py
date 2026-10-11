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
