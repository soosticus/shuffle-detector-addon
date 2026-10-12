"""Quantity calculator: shopping list, expected output and profit range for a chosen shuffle."""

import math
from dataclasses import dataclass, field

from . import calc

Z90 = 1.645            # two-sided 90% interval under a normal approximation
MAX_CRAFTS = 100_000   # search cap when buying is unconstrained (e.g. vendor-only reagents)


@dataclass
class Purchase:
    item: int
    name: str
    qty: int
    ah_qty: int = 0
    ah_cost: float = 0
    vendor_qty: int = 0
    vendor_cost: float = 0
    short: int = 0    # units that can be bought from neither the AH nor a vendor
    note: str = ""    # e.g. "makes 8 x Bolt of Silk Cloth"

    @property
    def total(self):
        return self.ah_cost + self.vendor_cost

    @property
    def unit(self):
        bought = self.ah_qty + self.vendor_qty
        return self.total / bought if bought else None


@dataclass
class Output:
    item: int
    name: str
    expected: float
    low: int
    high: int
    unit: float | None    # market price per unit, None if unlisted
    value: float | None   # expected gross value, None if unlisted


@dataclass
class Batch:
    result: calc.Result
    crafts: int
    requested: int | None = None      # crafts asked for (crafts mode)
    budget: float | None = None       # copper (budget mode)
    limited_by: str = ""              # "", "availability", "budget" or "cap"
    purchases: list = field(default_factory=list)
    cost: float = 0
    exit: str = ""
    outputs: list = field(default_factory=list)
    revenue: float | None = None      # net of the AH cut, expected
    revenue_low: float | None = None
    revenue_high: float | None = None
    profit: float | None = None
    profit_low: float | None = None
    profit_high: float | None = None
    roi: float | None = None
    seconds: float = 0                # casting time for the whole batch
    profit_per_hour: float | None = None
    notes: list = field(default_factory=list)


def parse_money(text):
    """'1g 20s 5c', '50g' or a bare number of copper -> copper (int). Raises ValueError."""
    text = text.strip().lower().replace(" ", "")
    if text.isdigit():
        return int(text)
    total, num, seen = 0, "", False
    for ch in text:
        if ch.isdigit() or (ch == "." and num and "." not in num):
            num += ch
        elif ch in "gsc" and num:
            total += float(num) * {"g": 10000, "s": 100, "c": 1}[ch]
            num, seen = "", True
        else:
            raise ValueError(f"can't read {text!r} as money (try 50g, 12g 30s or 5000)")
    if num or not seen:
        raise ValueError(f"can't read {text!r} as money (try 50g, 12g 30s or 5000)")
    return int(round(total))


def realm_items(scan, realm=None):
    """Scanned prices for `realm` (default: the first realm, as calc.rank picks it)."""
    realm = realm or next(iter(sorted(scan.scans)), None)
    return scan.scans[realm]["items"] if realm in scan.scans else {}


def _segments(entry):
    """Ascending (unit price, count) listings; units beyond the stored depth are priced at the last listed price."""
    listed, last = 0, entry["min"]
    for unit, count in entry["prices"]:
        yield unit, count
        listed += count
        last = unit
    if entry["qty"] > listed:
        yield last, entry["qty"] - listed


def buy_mix(entry, vendor_unit, qty):
    """Cheapest way to obtain `qty` units: (ah_qty, ah_cost, vendor_qty, vendor_cost, short)."""
    ah_qty, ah_cost, need = 0, 0.0, qty
    if entry:
        for unit, count in _segments(entry):
            if need <= 0 or (vendor_unit is not None and unit >= vendor_unit):
                break
            take = min(count, need)
            ah_qty += take
            ah_cost += unit * take
            need -= take
    if need > 0 and vendor_unit is not None:
        return ah_qty, ah_cost, need, vendor_unit * need, 0
    return ah_qty, ah_cost, 0, 0.0, max(need, 0)


def _refined_sources(bolt, qty, items, ref):
    """Ways to get bolts as (cost per bolt, count, "bolt" | "cloth"), cheapest first: buy them, or buy raw cloth."""
    cloth, per = ref.refined[bolt]
    sources = []
    if items.get(bolt):
        sources += [(u, c, "bolt") for u, c in _segments(items[bolt])]
    if ref.vendor.get(bolt) is not None:
        sources.append((ref.vendor[bolt], qty, "bolt"))
    if items.get(cloth):
        carry = 0
        for unit, count in _segments(items[cloth]):
            made, carry = divmod(carry + count, per)
            if made:
                sources.append((unit * per, made, "cloth"))
    if ref.vendor.get(cloth) is not None:
        sources.append((ref.vendor[cloth] * per, qty, "cloth"))
    return sorted(sources, key=lambda s: (s[0], s[2]))


def _refined_purchases(bolt, qty, items, ref):
    """Cheapest mix of bought bolts and bolts made from raw cloth, as purchases of the bolt and of the cloth."""
    cloth, per = ref.refined[bolt]
    taken, need = {"bolt": 0, "cloth": 0}, qty
    for _, count, kind in _refined_sources(bolt, qty, items, ref):
        if need <= 0:
            break
        take = min(count, need)
        taken[kind] += take
        need -= take
    out = []
    if taken["bolt"] or need or not taken["cloth"]:
        p = Purchase(bolt, ref.name(bolt), taken["bolt"] + need,
                     *buy_mix(items.get(bolt), ref.vendor.get(bolt), taken["bolt"]))
        p.short += need
        out.append(p)
    if taken["cloth"]:
        units = taken["cloth"] * per
        p = Purchase(cloth, ref.name(cloth), units, *buy_mix(items.get(cloth), ref.vendor.get(cloth), units))
        p.note = f"makes {taken['cloth']} x {ref.name(bolt)}"
        out.append(p)
    return out


def shopping_list(recipe, items, ref, crafts):
    out = []
    for r in recipe["reagents"]:
        qty = r["qty"] * crafts
        if r["item"] in ref.refined:
            out += _refined_purchases(r["item"], qty, items, ref)
            continue
        mix = buy_mix(items.get(r["item"]), ref.vendor.get(r["item"]), qty)
        out.append(Purchase(r["item"], ref.name(r["item"]), qty, *mix))
    return out


def max_crafts(ok, cap=MAX_CRAFTS):
    """Largest n in [0, cap] with ok(n), assuming ok is true up to some point and false after."""
    lo, hi = 0, 1
    while hi <= cap and ok(hi):
        lo, hi = hi, hi * 2
    hi = min(hi, cap + 1)
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if ok(mid):
            lo = mid
        else:
            hi = mid
    return lo


def _outputs(result, crafts, cut):
    """Expected outputs and the standard deviation of net revenue (yields modelled as Poisson counts)."""
    outs, var = [], 0.0
    if result.exit == "Disenchant":
        for y in result.yields:
            mean = y.qty * crafts
            sd = math.sqrt(mean)
            outs.append(Output(y.item, y.name, mean, max(0, math.floor(mean - Z90 * sd)),
                               math.ceil(mean + Z90 * sd), y.unit, y.unit * mean if y.unit is not None else None))
            if y.unit is not None:
                var += (y.unit * (1 - cut)) ** 2 * mean
    elif result.crafted:
        c = result.crafted
        unit = c.ah_unit if result.exit == "Sell on AH" else c.vendor_unit
        total = c.qty * crafts
        outs.append(Output(c.item, c.name, total, math.floor(total), math.ceil(total), unit,
                           unit * total if unit is not None else None))
    return outs, math.sqrt(var)


def calculate(result, items, ref, settings, crafts=None, budget=None):
    """Plan a batch of `crafts` crafts, or as many as `budget` copper buys. `items` is the realm's scanned prices."""
    if (crafts is None) == (budget is None):
        raise ValueError("give exactly one of crafts or budget")
    recipe = result.recipe

    def feasible(n):
        return all(p.short == 0 for p in shopping_list(recipe, items, ref, n))

    def affordable(n):
        plan = shopping_list(recipe, items, ref, n)
        return all(p.short == 0 for p in plan) and sum(p.total for p in plan) <= budget

    batch = Batch(result, 0, requested=crafts, budget=budget, exit=result.exit)
    if budget is not None:
        n = max_crafts(affordable)
        if n >= MAX_CRAFTS:
            batch.limited_by = "cap"
        else:
            batch.limited_by = "availability" if not feasible(n + 1) else "budget"
    else:
        n = crafts if feasible(crafts) else max_crafts(feasible)
        batch.limited_by = "" if n == crafts else "availability"
    batch.crafts = n
    batch.purchases = shopping_list(recipe, items, ref, n)
    batch.cost = sum(p.total for p in batch.purchases)

    if n and result.net is not None:
        batch.outputs, sd = _outputs(result, n, settings.ah_cut)
        batch.revenue = result.net * n
        batch.revenue_low = max(0.0, batch.revenue - Z90 * sd)
        batch.revenue_high = batch.revenue + Z90 * sd
        batch.profit = batch.revenue - batch.cost
        batch.profit_low = batch.revenue_low - batch.cost
        batch.profit_high = batch.revenue_high - batch.cost
        batch.roi = batch.profit / batch.cost if batch.cost else None
    batch.seconds = result.seconds * n
    if batch.profit is not None and batch.seconds > 0:
        batch.profit_per_hour = batch.profit / batch.seconds * 3600
    if n == 0:
        batch.notes.append("Nothing can be bought with these limits.")
    if batch.limited_by == "availability" and crafts is not None:
        batch.notes.append(f"Only {n} of the {crafts} requested crafts can be bought: reagents are not listed in enough quantity.")
    if batch.limited_by == "cap":
        batch.notes.append(f"Capped at {MAX_CRAFTS} crafts.")
    if n and result.net is None:
        batch.notes.append("No sale price for this shuffle, so revenue and profit are unknown.")
    if any(o.unit is None for o in batch.outputs):
        batch.notes.append("Some outputs have no price and are not valued.")
    if result.exit == "Disenchant":
        batch.notes.append("Range is 90%, assuming disenchant yields are independent Poisson counts; "
                           "it is rough for small batches.")
    if n:
        batch.notes.append("Time is casting time only (crafts and disenchants); it leaves out buying, selling, "
                           "and making bolts, bars and the like from raw materials.")
        batch.notes.append("Sale value uses current prices; selling many units will push the price down.")
    return batch


def format_batch(b):
    """Plain-text report for the CLI."""
    m = calc.fmt_money
    lines = [f"{b.result.name}: {b.crafts} crafts" + (f" (limited by {b.limited_by})" if b.limited_by else "")]
    lines.append("Buy:")
    for p in b.purchases:
        where = ", ".join(x for x in (f"{p.ah_qty} AH = {m(p.ah_cost)}" if p.ah_qty else "",
                                       f"{p.vendor_qty} vendor = {m(p.vendor_cost)}" if p.vendor_qty else "",
                                       f"{p.short} unavailable" if p.short else "") if x)
        lines.append(f"  {p.qty} x {p.name}: {where or '-'}  (total {m(p.total)})" + (f" [{p.note}]" if p.note else ""))
    lines.append(f"Total cost: {m(b.cost)}")
    if b.seconds:
        lines.append(f"Expected time: {calc.fmt_duration(b.seconds)}")
    if b.outputs:
        lines.append(f"Expected output ({b.exit}):")
        for o in b.outputs:
            rng = f" (90%: {o.low}-{o.high})" if o.low != o.high else ""
            lines.append(f"  {o.expected:.1f} x {o.name}{rng} @ {m(o.unit)} = {m(o.value)}")
    if b.profit is not None:
        spread = b.revenue_low != b.revenue_high
        rng = lambda lo, hi: f" (90%: {m(lo)} to {m(hi)})" if spread else ""
        lines.append(f"Net revenue: {m(b.revenue)}{rng(b.revenue_low, b.revenue_high)}")
        roi = f", ROI {b.roi * 100:.0f}%" if b.roi is not None else ""
        lines.append(f"Profit: {m(b.profit)}{rng(b.profit_low, b.profit_high)}{roi}")
        if b.profit_per_hour is not None:
            lines.append(f"Profit per hour: {m(b.profit_per_hour)}")
    lines += [f"Note: {n}" for n in b.notes]
    return "\n".join(lines)
