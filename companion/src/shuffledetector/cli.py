"""Command-line interface."""

import argparse
import sys

from . import addon_manager, calc, data_loader, plan


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
    p.add_argument("--top", type=int, default=10)
    p.add_argument("--update-wowhead", action="store_true", help="download recipes/yields/vendor prices from Wowhead (Forever)")
    p.add_argument("--refresh", action="store_true", help="with --update-wowhead: ignore the page cache")
    p.add_argument("--send-plan", metavar="RECIPE", help="write this recipe's shuffle to the addon's Plan.lua (then /reload in game)")
    p.add_argument("--wow", help="WoW folder, flavor folder or AddOns folder to send the plan to (default: auto-detect)")
    p.add_argument("--detail", action="store_true", help="show step-by-step breakdown")
    return p


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
    if args.update_wowhead:
        from . import wowhead
        def show(done, total, msg):
            print(f"\r[{done}/{total}] {msg:<40}", end="", flush=True)
        out, n = wowhead.update(progress=show, use_cache=not args.refresh)
        print(f"\nWrote {n} recipes to {out}")
        return 0
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
    settings = calc.Settings(ah_cut=args.ah_cut, price_mode=args.price_mode, exits=exits)
    results = calc.rank(scan, ref, settings, args.realm, args.character)
    if args.send_plan:
        return send_plan(args, results)
    for r in results[: args.top]:
        print(f"{r.name:<28} profit {calc.fmt_money(r.profit):>12}  cost {calc.fmt_money(r.cost):>12}  via {r.exit:<11} [{r.status}]")
        if args.detail:
            for l in r.reagents:
                print(f"    buy   {l.qty:g} x {l.name} ({l.source}) = {calc.fmt_money(l.total)}  [AH {calc.fmt_money(l.ah_unit)}, vendor {calc.fmt_money(l.vendor_unit)}]")
            for e in r.exits:
                print(f"    exit  {e.label:<11} {calc.fmt_money(e.net)}{' <-' if e.label == r.exit else ''}")
            for l in r.yields:
                print(f"    yield {l.qty:g} x {l.name} @ {calc.fmt_money(l.unit)} = {calc.fmt_money(l.total)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
