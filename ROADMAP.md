# Roadmap

Open items only; finished work is removed. Release notes are hand-written in `release-notes/<tag>.md` (see CLAUDE.md).

## Open items

- Handle vendor faction/location restrictions.
- Confirm in game that the addon loads with its Auctionator dependency and that the companion shows prices after an Auctionator scan and `/reload` (prices are read from `Auctionator.lua`, see `auctionator.py`). Open question: the realm key (`PvE`, `ClassicBetaPvE2`) with the freshest data is picked by default; check it is the right realm.
- Confirm in game that the fast-press gating no longer repeats a craft or disenchant step.
- Confirm in game that the Vendor sell step (addon 0.7.2) works. AH listing is out of scope (Auctionator and similar addons do it); AH exits only prompt.
- Shuffle follow-up: take the craft count or budget from the calculator.
- Calculator follow-ups: model price impact when buying or selling large quantities (walk the sell side of the order book), and offer a "number of disenchants" target. Use the observed disenchant results (data plan step 3) for the range instead of Poisson once there are enough samples.
- Try the companion self-update (`selfupdate.py`) against a real release: the Windows swap script is verified locally, macOS (`ditto`, `open`) and Linux are untested, and it needs a published release newer than the installed build.
- Check that pushing the re-pointed `v0.2.4a` tag after the history rewrite did not start an unwanted release run (`release.yml` triggers on `v*` tags).

## Data plan: a permitted source for recipe, price and yield data

Rule: never scrape Wowhead or any other site against its terms (all Wowhead data and code is gone). Check the terms before using any source, and keep end users from downloading anything from a third-party site themselves. Layout of what the addon records is in `common/docs/FORMAT.md`; the output shape (`items`, `vendor`, `vendor_sell`, `recipes` with `profession`, `makes`, `reagents`, `yields`, `skill`, `refined`) stays the same so the calculator does not change.

Done and confirmed in game: step 1 (the addon records known recipes with reagents, item names and sell prices), step 2 (unlearned recipes in `available`, vendor buy prices in `vendor`), and the addon requesting names and sell prices for every id in `ItemList.lua` (`--send-items`). `GetRecipeSourceText` never returns a value on this client, so `source` is unused.

### Steps 1 and 2 follow-ups

- Open the remaining profession windows on each character (Alchemy, Cooking on the second character) and confirm they record; check Mining/smelting, Blacksmithing, Leatherworking, Engineering and First Aid when a character has them.
- Recorded recipes have no skill requirement (only the trivial level), so a recipe known by one character shows as learnable for another until a source supplies skill levels.
- Record names for scanned items too (the scan stores IDs only, so items outside the recipes show as "Item N" unless the bundled data names them).
- Confirm the merchant recorder keeps only unlimited-stock listings: visit a vendor with limited-stock goods and check they are absent from `AHSnapshotDB.vendor`.
- Open question: the companion could drop recipes whose product or reagents are in `AHSnapshotDB.unanswered` (about 260 ids that are not items in this client).
- Local-install route (`--local-recipes`, `casc.py`, `db2.py`, `localdata.py`; reads reagents, products, trivial levels and craft times for about 2300 recipes from the user's own client, nothing downloaded or bundled). Next: a GUI toggle, a JSON cache of the result, Enchanting recipes (no product item), mapping recipes to the characters' professions, and checking its `makes` (always 1) against the addon's recorded value (addon data wins). Limits: the WDC5 reader skips encrypted sections and sparse tables, so `ItemSparse` (base `BuyPrice`) would need sparse support, and recipe skill requirements are not in the client.
- wago.tools (client tables, would give skill requirements) is **paused**: its `robots.txt` disallows everything except the home page and it has no terms page, so do not fetch it. Only its author (Discord or GitHub `QartemisT`) can grant permission. Rechecked 2026-10-12, still disallowed.

### Step 3: disenchant yields (built; not yet confirmed in game)

Two sources, no site involved. The companion reads Auctionator's disenchant table from the installed addon's files (`deyields.py`; the game does not load it on this client, so it cannot be read in game) and the addon records each item's class, quality and item level in `AHSnapshotDB.items`. `Disenchant.lua` logs each real disenchant to `AHSnapshotDB.disenchants`, and once an item has samples the companion's average of those wins (`data_loader.observed_yields`). Precedence: observed, then Auctionator, then the seed `yields`.

To confirm: `/shuffledetector yields`, `/reload`, check that items in `AHSnapshotDB.items` have `class`/`quality`/`ilvl` and that the companion shows "Auctionator disenchant table" for crafted armor. Also disenchant a few items (check that `SpellTargetItem` fires for a disenchant driven by the shuffle button's `target-item` attribute) and check `AHSnapshotDB.disenchants`.

## Planned: faster and automatic reference data builds

Only relevant if the wago.tools route (paused above) is ever allowed; the addon-recorded data needs none of this.

- Incremental builds keyed on the client build number, a weekly scheduled workflow that rebuilds and publishes the data when it changes (test one manual run first; only if the source's terms allow automated downloads), and a companion "download latest data" option that fetches from our own release.
- Confirm the source's terms allow republishing the derived bundle before making the repo public.

## Planned: more professions

The companion evaluates every crafting profession in this client (Tailoring, Leatherworking, Blacksmithing, Engineering, Enchanting, Alchemy, Mining/smelting, Cooking and First Aid). What is left:

- Confirm the addon records known recipes for every profession (only verified for Tailoring, Enchanting and Cooking); the "known only" filter falls back to showing everything for a profession with none recorded. Also confirm the shuffle button can craft recipes of other professions when their window is open.
- Gathering and processing: Herbalism, Skinning and Mining as sources of raw materials, and buying or gathering inputs versus the AH price.
- Other exit steps (for example salvage) in the same exit comparison. Prospecting and milling do not exist in this client because it has no Jewelcrafting or Inscription.
- Allow chains across professions held by different characters (craft on one, process on another), and chains where one craft feeds another profession's craft.
- Per-recipe craft times: the calculator uses 30 s unless a recipe sets `craft_seconds`. Read the cast times from the game or the client tables (the local-install route already has them).
