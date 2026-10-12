"""Command-line interface."""

import argparse
import sys

from . import addon_manager, calc, calculator, data_loader, plan


def build_parser():
    p = argparse.ArgumentParser(prog="shuffledetector", description=__doc__)
    p.add_argument("savedvars", nargs="?", help="path to ShuffleDetector.lua (SavedVariables)")
    p.add_argument("--data", help="extra reference JSON overriding the bundled seed data")
    p.add_argument("--realm", help="realm-faction key (default: first scanned)")
    p.add_argument("--character", help="character key to use for known recipes/skill")
    p.add_argument("--ah-cut", type=float, default=0.05)
    p.add_argument("--price-mode", choices=calc.PRICE_MODES, default="avg_low")
    p.add_argument("--exits", default="disenchant,ah,vendor",
                   help="comma list of exit strategies to consider: disenchant, ah, vendor")
    p.add_argument("--craft-seconds", type=float, default=30.0, help="seconds to craft one piece (default 30)")
    p.add_argument("--disenchant-seconds", type=float, default=3.0, help="seconds to disenchant one piece (default 3)")
    p.add_argument("--profession", help="only show this profession (e.g. Tailoring, Alchemy, First Aid)")
    p.add_argument("--top", type=int, default=10)
    p.add_argument("--send-plan", metavar="RECIPE", help="write this recipe's shuffle to the addon's Plan.lua (then /reload in game)")
    p.add_argument("--wow", help="WoW folder, flavor folder or AddOns folder to send the plan to (default: auto-detect)")
    p.add_argument("--detail", action="store_true", help="show step-by-step breakdown")
    p.add_argument("--calc", metavar="RECIPE", help="plan a batch of this shuffle: what to buy, expected output and profit (needs --crafts or --budget)")
    p.add_argument("--crafts", type=int, help="with --calc: number of crafts")
    p.add_argument("--budget", help="with --calc: spend up to this much, e.g. 250g, 12g 30s or copper")
    return p


def calc_batch(args, results, scan, ref, settings):
    match = next((r for r in results if r.name.lower() == args.calc.lower()), None)
    if match is None:
        print(f"No recipe named {args.calc!r}.", file=sys.stderr)
        return 2
    if (args.crafts is None) == (args.budget is None):
        print("--calc needs exactly one of --crafts or --budget.", file=sys.stderr)
        return 2
    try:
        budget = calculator.parse_money(args.budget) if args.budget is not None else None
    except ValueError as e:
        print(e, file=sys.stderr)
        return 2
    if args.crafts is not None and args.crafts < 1:
        print("--crafts must be at least 1.", file=sys.stderr)
        return 2
    batch = calculator.calculate(match, calculator.realm_items(scan, args.realm), ref, settings,
                                 crafts=args.crafts, budget=budget)
    print(calculator.format_batch(batch))
    return 0


def send_plan(args, results):
    match = next((r for r in results if r.name.lower() == args.send_plan.lower()), None)
    if match is None:
        print(f"No recipe named {args.send_plan!r}.", file=sys.stderr)
        return 2
    installs = [i for i in addon_manager.discover_installs([args.wow] if args.wow else []) if i.installed_version]
    if not installs:
        print("No WoW install with the addon found; install the addon or pass --wow.", file=sys.stderr)
        return 2
    for inst in installs:
        print(f"Sent {match.name} ({match.exit}) to {plan.write_plan(inst, plan.build_plan(match))}")
    print("In game: /reload, then /shuffledetector shuffle")
    return 0


def main(argv=None):
    args = build_parser().parse_args(argv)
    path = args.savedvars
    if not path:
        found = data_loader.candidate_saved_variables()
        if not found:
            print("No SavedVariables file found; pass its path.", file=sys.stderr)
            return 2
        path = str(found[0])
    scan = data_loader.load_scan_data(path)
    ref = data_loader.load_reference(extra=args.data)
    exit_names = {"disenchant": "Disenchant", "ah": "Sell on AH", "vendor": "Vendor"}
    exits = tuple(exit_names[x] for x in args.exits.lower().replace(" ", "").split(",") if x in exit_names)
    settings = calc.Settings(ah_cut=args.ah_cut, price_mode=args.price_mode, exits=exits,
                             craft_seconds=args.craft_seconds, disenchant_seconds=args.disenchant_seconds)
    results = calc.rank(scan, ref, settings, args.realm, args.character,
                        professions=[args.profession] if args.profession else None)
    if args.send_plan:
        return send_plan(args, results)
    if args.calc:
        return calc_batch(args, results, scan, ref, settings)
    for r in results[: args.top]:
        print(f"{r.name:<28} {r.profession:<14} profit {calc.fmt_money(r.profit):>12}  cost {calc.fmt_money(r.cost):>12}  via {r.exit:<11} [{r.status}]")
        if args.detail:
            for l in r.reagents:
                print(f"    buy   {l.qty:g} x {l.name} ({l.source}) = {calc.fmt_money(l.total)}  [AH {calc.fmt_money(l.ah_unit)}, vendor {calc.fmt_money(l.vendor_unit)}"
                      + (f", raw {calc.fmt_money(l.raw_unit)}" if l.raw_item else "") + "]")
            per_hour = f", {calc.fmt_money(r.profit_per_hour)} profit/hour" if r.profit_per_hour is not None else ""
            print(f"    time  {calc.fmt_duration(r.seconds)} per craft{per_hour}")
            for e in r.exits:
                print(f"    exit  {e.label:<11} {calc.fmt_money(e.net)}{' <-' if e.label == r.exit else ''}")
            for l in r.yields:
                print(f"    yield {l.qty:g} x {l.name} @ {calc.fmt_money(l.unit)} = {calc.fmt_money(l.total)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
