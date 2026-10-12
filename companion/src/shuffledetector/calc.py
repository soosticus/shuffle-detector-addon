"""Profit calculation for crafting shuffles: craft something, then disenchant it or sell it."""

from dataclasses import dataclass, field

PRICE_MODES = ("avg_low", "min")
DEFAULT_PROFESSION = "Tailoring"  # recipes without a profession are Tailoring (the original seed data)


@dataclass
class Settings:
    ah_cut: float = 0.05          # auction house fee taken from sales
    price_mode: str = "avg_low"   # how to value items you sell
    low_units: int = 5            # units averaged by the avg_low mode
    exits: tuple = ("Disenchant", "Sell on AH", "Vendor")  # exit strategies considered
    craft_seconds: float = 30.0       # time to craft one piece (a recipe's own "craft_seconds" overrides this)
    disenchant_seconds: float = 3.0   # time to disenchant one piece


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
    raw_unit: float | None = None     # per-unit cost when made from the raw item (refined items such as bolts and bars)
    raw_item: int | None = None       # the raw item a refined item is made from
    raw_qty: int = 0                  # raw items per refined piece


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
    profession: str = DEFAULT_PROFESSION
    seconds: float = 0           # casting time per craft: the craft, plus the disenchant when that is the exit
    profit_per_hour: float | None = None

    @property
    def name(self):
        return self.recipe["name"]


def recipe_profession(recipe):
    return recipe.get("profession") or DEFAULT_PROFESSION


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


def _skills_and_known(characters, character):
    """({profession: best skill}, {profession: {known recipe names}}) over the chosen character (or all), keys lowercase."""
    chars = characters if character is None else {character: characters.get(character, {})}
    skills, known = {}, {}
    for c in chars.values():
        for pname, prof in (c.get("professions") or {}).items():
            key = pname.lower()
            skills[key] = max(skills.get(key) or 0, prof.get("skill") or 0)
            names = known.setdefault(key, set())
            for r in prof.get("recipes") or []:
                names.add(r.get("name", "").lower())
    return skills, known


def evaluate(recipe, items, ref, settings, skill=None, known=frozenset()):
    res = Result(recipe=recipe, profession=recipe_profession(recipe))
    makes = recipe.get("makes") or 1
    cost = 0
    for r in recipe["reagents"]:
        item, qty = r["item"], r["qty"]
        ah = buy_cost(items.get(item), qty)
        vendor = ref.vendor.get(item)
        vendor_total = vendor * qty if vendor is not None else None
        options = [(t, s) for t, s in ((ah, "AH"), (vendor_total, "Vendor")) if t is not None]
        # Bolts, bars and the like can also be made from their raw item; the cheapest of buying or making one wins.
        raw_total, raw_item, raw_per = None, None, 0
        if item in ref.refined:
            raw_item, raw_per = ref.refined[item]
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
        res.crafted = Line(crafted_id, ref.name(crafted_id), makes, None, None, "", ah_price, vendor_price)
    if recipe["yields"]:
        res.exits.append(Exit("Disenchant", de_net, "" if gross else "no priced yields"))
    if ah_price is not None:
        res.exits.append(Exit("Sell on AH", ah_price * makes * (1 - settings.ah_cut)))
    if vendor_price:
        res.exits.append(Exit("Vendor", float(vendor_price) * makes))
    priced = [e for e in res.exits if e.net and e.label in settings.exits]
    best = max(priced, key=lambda e: e.net) if priced else None
    res.net = best.net if best else None
    res.exit = best.label if best else "-"
    res.allowed = tuple(settings.exits)
    if res.cost is not None and res.net is not None:
        res.profit = res.net - res.cost
        res.roi = res.profit / res.cost if res.cost else None
    res.seconds = recipe.get("craft_seconds", settings.craft_seconds) + (
        settings.disenchant_seconds if res.exit == "Disenchant" else 0)
    if res.profit is not None and res.seconds > 0:
        res.profit_per_hour = res.profit / res.seconds * 3600
    if recipe["name"].lower() in known:
        res.status = "known"
    elif skill is None:
        res.status = "unknown"
    elif skill >= recipe.get("skill", 0):
        res.status = "learnable"
    else:
        res.status = "needs_skill"
    return res


def rank(scan, ref, settings=None, realm=None, character=None, professions=None):
    """Evaluate all recipes for a realm; best profit first (incomplete data last)."""
    settings = settings or Settings()
    realm = realm or next(iter(sorted(scan.scans)), None)
    if realm is None:
        return []
    items = scan.scans[realm]["items"]
    skills, known = _skills_and_known(scan.characters, character)
    wanted = {p.lower() for p in professions} if professions else None
    results = []
    for r in ref.recipes:
        key = recipe_profession(r).lower()
        if wanted is None or key in wanted:
            results.append(evaluate(r, items, ref, settings, skills.get(key), known.get(key, frozenset())))
    results.sort(key=lambda r: (r.profit is None, -(r.profit or 0)))
    return results


def suggestions(results):
    """Profitable recipes you do not know yet, best first."""
    return [r for r in results if r.status != "known" and r.profit is not None and r.profit > 0]


def fmt_duration(seconds):
    """Format seconds as '1h 5m', '12m 30s' or '45s'."""
    s = int(round(seconds))
    h, rem = divmod(s, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m}m"
    return f"{m}m {s}s" if m else f"{s}s"


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
