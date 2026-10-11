"""Profit calculation for Tailoring -> Enchanting shuffles."""

from dataclasses import dataclass, field

PRICE_MODES = ("avg_low", "min")


@dataclass
class Settings:
    ah_cut: float = 0.05          # auction house fee taken from sales
    price_mode: str = "avg_low"   # how to value items you sell
    low_units: int = 5            # units averaged by the avg_low mode
    exits: tuple = ("Disenchant", "Sell on AH", "Vendor")  # exit strategies considered


@dataclass
class Line:
    item: int
    name: str
    qty: float
    unit: float | None
    total: float | None
    source: str = ""
    ah_unit: float | None = None      # per-unit AH price (what it would cost / fetch)
    vendor_unit: float | None = None  # per-unit vendor price
    raw_unit: float | None = None     # per-unit cost when made from raw cloth (bolts only)
    raw_item: int | None = None       # the raw cloth item a bolt is made from
    raw_qty: int = 0                  # raw cloth per bolt


@dataclass
class Exit:
    label: str
    net: float | None   # per craft, after fees
    note: str = ""


@dataclass
class Result:
    recipe: dict
    reagents: list = field(default_factory=list)
    yields: list = field(default_factory=list)
    cost: float | None = None
    gross: float | None = None   # disenchant value before AH cut
    net: float | None = None     # net of the best exit
    profit: float | None = None
    roi: float | None = None
    status: str = "unknown"      # known | learnable | needs_skill | unknown
    missing: list = field(default_factory=list)
    crafted: Line | None = None
    exits: list = field(default_factory=list)
    exit: str = ""               # label of the chosen exit
    allowed: tuple = ()          # exits that were enabled for this evaluation

    @property
    def name(self):
        return self.recipe["name"]


def buy_cost(entry, qty):
    """Cost to buy `qty` units by walking the cheapest listings; None if unavailable."""
    if not entry or entry["qty"] < qty:
        return None
    remaining, total, last = qty, 0, entry["min"]
    for unit, count in entry["prices"]:
        take = min(count, remaining)
        total += unit * take
        remaining -= take
        last = unit
        if remaining <= 0:
            return total
    return total + last * remaining


def sell_price(entry, settings):
    """Per-unit value of an item you would sell; None if not listed."""
    if not entry:
        return None
    if settings.price_mode == "min" or not entry["prices"]:
        return entry["min"]
    remaining, total = settings.low_units, 0
    for unit, count in entry["prices"]:
        take = min(count, remaining)
        total += unit * take
        remaining -= take
        if remaining <= 0:
            break
    taken = settings.low_units - remaining
    return total / taken if taken else entry["min"]


def _skill_and_known(characters, character):
    chars = characters if character is None else {character: characters.get(character, {})}
    known, skill = set(), None
    for c in chars.values():
        for pname, prof in (c.get("professions") or {}).items():
            if pname.lower() == "tailoring":
                skill = max(skill or 0, prof.get("skill") or 0)
                for r in prof.get("recipes") or []:
                    known.add(r.get("name", "").lower())
    return skill, known


def evaluate(recipe, items, ref, settings, skill=None, known=frozenset()):
    res = Result(recipe=recipe)
    cost = 0
    for r in recipe["reagents"]:
        item, qty = r["item"], r["qty"]
        ah = buy_cost(items.get(item), qty)
        vendor = ref.vendor.get(item)
        vendor_total = vendor * qty if vendor is not None else None
        options = [(t, s) for t, s in ((ah, "AH"), (vendor_total, "Vendor")) if t is not None]
        # Bolts can also be crafted from raw cloth; the cheapest of buying a bolt or making one wins.
        raw_total, raw_item, raw_per = None, None, 0
        if item in ref.bolts:
            raw_item, raw_per = ref.bolts[item]
            need = raw_per * qty
            cloth_vendor = ref.vendor.get(raw_item)
            raw_options = [t for t in (buy_cost(items.get(raw_item), need),
                                       cloth_vendor * need if cloth_vendor is not None else None) if t is not None]
            if raw_options:
                raw_total = min(raw_options)
                options.append((raw_total, f"Craft from {ref.name(raw_item)}"))
        if options:
            total, source = min(options)
            res.reagents.append(Line(item, ref.name(item), qty, total / qty, total, source,
                                     ah / qty if ah is not None else None, vendor,
                                     raw_total / qty if raw_total is not None else None, raw_item, raw_per))
            cost += total
        else:
            res.reagents.append(Line(item, ref.name(item), qty, None, None, "unavailable", None, vendor,
                                     None, raw_item, raw_per))
            res.missing.append(ref.name(item))
    gross = 0
    for y in recipe["yields"]:
        price = sell_price(items.get(y["item"]), settings)
        if price is None:
            res.yields.append(Line(y["item"], ref.name(y["item"]), y["avg"], None, None, "no listings"))
            res.missing.append(ref.name(y["item"]))
        else:
            res.yields.append(Line(y["item"], ref.name(y["item"]), y["avg"], price, price * y["avg"], "AH"))
            gross += price * y["avg"]
    if not any(l.source == "unavailable" for l in res.reagents):
        res.cost = cost
    res.gross = gross
    de_net = gross * (1 - settings.ah_cut)

    # Crafted item: it can be disenchanted, sold on the AH, or sold to a vendor.
    crafted_id = recipe.get("item")
    ah_price = sell_price(items.get(crafted_id), settings) if crafted_id else None
    vendor_price = ref.vendor_sell.get(crafted_id) if crafted_id else None
    if crafted_id:
        res.crafted = Line(crafted_id, ref.name(crafted_id), 1, None, None, "", ah_price, vendor_price)
    res.exits.append(Exit("Disenchant", de_net if recipe["yields"] else None,
                          "" if gross else "no priced yields"))
    if ah_price is not None:
        res.exits.append(Exit("Sell on AH", ah_price * (1 - settings.ah_cut)))
    if vendor_price:
        res.exits.append(Exit("Vendor", float(vendor_price)))
    priced = [e for e in res.exits if e.net and e.label in settings.exits]
    best = max(priced, key=lambda e: e.net) if priced else None
    res.net = best.net if best else None
    res.exit = best.label if best else "-"
    res.allowed = tuple(settings.exits)
    if res.cost is not None and res.net is not None:
        res.profit = res.net - res.cost
        res.roi = res.profit / res.cost if res.cost else None
    if recipe["name"].lower() in known:
        res.status = "known"
    elif skill is None:
        res.status = "unknown"
    elif skill >= recipe.get("skill", 0):
        res.status = "learnable"
    else:
        res.status = "needs_skill"
    return res


def rank(scan, ref, settings=None, realm=None, character=None):
    """Evaluate all recipes for a realm; best profit first (incomplete data last)."""
    settings = settings or Settings()
    realm = realm or next(iter(sorted(scan.scans)), None)
    if realm is None:
        return []
    items = scan.scans[realm]["items"]
    skill, known = _skill_and_known(scan.characters, character)
    results = [evaluate(r, items, ref, settings, skill, known) for r in ref.recipes]
    results.sort(key=lambda r: (r.profit is None, -(r.profit or 0)))
    return results


def suggestions(results):
    """Profitable recipes you do not know yet, best first."""
    return [r for r in results if r.status != "known" and r.profit is not None and r.profit > 0]


def fmt_money(copper):
    """Format copper as 'Xg Ys Zc'."""
    if copper is None:
        return "-"
    sign = "-" if copper < 0 else ""
    c = int(round(abs(copper)))
    g, rem = divmod(c, 10000)
    s, c = divmod(rem, 100)
    parts = [f"{g}g"] if g else []
    if s or g:
        parts.append(f"{s}s")
    parts.append(f"{c}c")
    return sign + " ".join(parts)
