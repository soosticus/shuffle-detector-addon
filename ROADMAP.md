# Roadmap

Open items only; finished work is removed. Release notes are hand-written in `release-notes/<tag>.md` (see CLAUDE.md).

## Open items

- Confirm in game that AH polling started by a craft press, and quote/confirm presses during
  a craft cast, work without interrupting the craft queue.

- Recipe catalog: confirm in game that the browser's automatic scan (or `/shuffledetector catalog`) finds recipes of
  professions no character has (the scan's check line should report most recorded
  Tailoring/Enchanting/Cooking recipes as found), how long the 1-500000 scan takes,
  and that the profession names match `GetProfessionInfo`'s. If the client only
  describes open professions, the browser still lists alts' professions.

- Disenchant yields in game (next release, 0.10.0, a release candidate for 1.0.0):
  disenchant exits are disabled in the browser until a trusted yield model exists.
  On Forever, Auctionator loads its disenchant code but not its probability table
  (`/shuffledetector prices 4343 6239` returned nil for Brown Linen Pants and Red
  Linen Vest; the diagnostic reports "probability table loaded=false"), and that
  table is All Rights Reserved, so it cannot be copied. Candidate: CMaNGOS ClassicDB
  (github.com/cmangos/classic-db, GPLv3 plus a COPYRIGHT.md fair-use notice) has
  populated `disenchant_loot_template` rows (entry = ilvl*100 + quality; chance,
  min/max count). It models Vanilla 1.12, not Forever, and redistribution rights are
  not established. Needs a user decision before use; if adopted, ship it as an
  uncertain opt-in model until logged disenchants (`AHSnapshotDB.disenchants` and its
  aggregates) confirm it (rare outcomes need well over 10 samples per bracket). The
  addon records each item's `class`/`quality`/`ilvl`; items crafted by Enchanters
  (wands) cannot be disenchanted. Do not waive the gates to hide missing data.

- Confirm in game: browser preferences and custom material costs survive `/reload`;
  Auctionator's v1 API keeps working (the version gate was removed; breaks are fixed
  when they occur). Age units, `RegisterForDBUpdate`, exactness/gear variants and
  depth remain unverified.

- Confirm batch statistics in game: confirmed vendor/AH purchases, macro vendor-sale bag/gold matching, raw conversions, multi-output averages, uncertain/reloaded sales and purchase reconciliation. Check frozen estimates, AddOn Settings link, chart layout, history rollover and manual-entry undo. Cash-flow trends are not a causal income-improvement baseline; automatic AH-proceeds attribution remains a follow-up.

- Handle vendor faction/location restrictions.
- Confirm in game that the fast-press gating no longer repeats a craft or disenchant step.
- Confirm space-limited finished-item craft batches in game: reserve two empty general-purpose slots, account for unlocked partial output stacks and multi-output recipes, stop at materials/target, then drain the full batch through vendor or disenchant presses. Check interruption, full bags and loot headroom; queue/capacity behavior is covered by the Lua harness.
- Confirm in game that the Vendor sell step (addon 0.7.2) works. AH listing is out of scope (Auctionator and similar addons do it); AH exits only prompt.
- Shuffle follow-up: take the craft count or budget from the calculator.
- Confirm the in-game material snatcher on Forever 1.60.1: set a multi-output shuffle active, set a small target with cheap materials, test merchant bundles/stock, AH item buyouts and commodity quote/confirmation, price changes, mailbox collection, reload recovery and Auctionator interference. Implementation has a Lua API stub harness; protected actions and real server events are not verified in game.
- Confirm raw linen/bolt shopping and macro preparation in game: open Tailoring to record Bolt of Linen Cloth, set the cloth cap and a small bag target, verify the read-only bolt cap is twice the cloth cap (zero disables both), mail reservations, cheaper-source switching, then collect and press the shuffle macro to queue the remaining batch's bolts before bags. Check queue completion, fast presses between casts, interruption/retry and full bags. Single-input/single-output refinement and queue gating are covered by the Lua harness; real queued casts still need confirmation.
- Confirm the single-button purchase flow in game: saved limits, macro-driven vendor buys, AH polling, item buyouts and separate commodity quote/confirmation presses; waiting states, down/up deduplication, combat and mail collection. Panel buttons share the same reservations; real protected purchase behavior remains unverified.
- Confirm craft-first macro progression and bag-bounded vendor purchases in game:
  the 2026-11-12 log showed thread stockpiling filling bags and leaving an uncertain
  vendor purchase. Ready crafts/raw preparation now precede more shopping, and vendor
  buys preserve two general slots when capacity APIs are available. Uncertain vendor
  purchases (game error, timeout or reload) now settle from the bag count; confirm that
  the macro resumes after an "Inventory is full" vendor error, and that the AH poll
  status (cheapest vs limit, not enough gold, none listed, own listing, AH busy)
  appears under the waiting label, and that offers larger than your gold shrink to
  an affordable quantity, and that one press buys up to five stacks of a vendor reagent as several one-stack purchases. Check the raw
  row's unfilled-bolt count and decreasing raw requirement as bolts enter bags.
- Confirm the merged batch/shuffle window in game: compact 60-pixel material rows with right-hand prices, More/Less controls expansion and recovery-button access, layout at your UI scale, live craft/purchase state, drag/position restoration, and `/shuffledetector shuffle` / `snatch` toggling the same window. The action macro remains independent of visibility; hiding the window stops polling but does not erase settings. Collapsing controls alone does not stop polling.
- Snatcher follow-ups: unattended vendor purchasing only if client restrictions permit it; multi-step or shared-raw intermediate chains, multi-output intermediates, and bank inventory. AH buying remains click-confirmed.
- Calculator follow-ups: model price impact when buying or selling large quantities (walk the sell side of the order book), and offer a "number of disenchants" target. Use the observed disenchant results (data plan step 3) for the range instead of Poisson once there are enough samples.
- Check that pushing the re-pointed `v0.2.4a` tag after the history rewrite did not start an unwanted release run (`release.yml` triggers on `v*` tags).

## Data plan: a permitted source for recipe, price and yield data

Rule: never scrape Wowhead or any other site against its terms (all Wowhead data and code is gone). Check the terms before using any source, and keep end users from downloading anything from a third-party site themselves. Layout of what the addon records is in `docs/FORMAT.md`.

Done and confirmed in game: step 1 (the addon records known recipes with reagents, item names and sell prices), step 2 (unlearned recipes in `available`, vendor buy prices in `vendor`), and the addon requesting names and sell prices for item ids (now every item of the recorded and catalog recipes). `GetRecipeSourceText` never returns a value on this client, so `source` is unused.

### Steps 1 and 2 follow-ups

- Open the remaining profession windows on each character (Alchemy, Cooking on the second character) and confirm they record; check Mining/smelting, Blacksmithing, Leatherworking, Engineering and First Aid when a character has them.
- Recorded recipes have no skill requirement (only the trivial level), so a recipe known by one character shows as learnable for another until a source supplies skill levels.
- Record names for scanned items too (the scan stores IDs only, so items outside the recipes show as "Item N" unless the bundled data names them).
- Confirm the merchant recorder keeps only unlimited-stock listings: visit a vendor with limited-stock goods and check they are absent from `AHSnapshotDB.vendor`.
- Open question: the browser could drop recipes whose product or reagents are in `AHSnapshotDB.unanswered` (about 260 ids that are not items in this client).
- wago.tools (client tables, would give skill requirements) is **paused**: its `robots.txt` disallows everything except the home page and it has no terms page, so do not fetch it. Only its author (Discord or GitHub `QartemisT`) can grant permission. Rechecked 2026-10-12, still disallowed.

### Step 3: logged disenchants (built; not yet confirmed in game)

`Disenchant.lua` logs each real disenchant to `AHSnapshotDB.disenchants`, binding targets to cast start (including an explicit shuffle-button target), checking one-item consumption, retrying delayed complete loot, skipping partial results and recording capture/client metadata. Raw history is capped at 500; build/realm/item aggregates keep complete identified samples beyond rollover. Lua stub checks cover these paths; actual event ordering and secure targets still need confirmation. Using these samples in the browser is part of the 0.10.0 item above.

To confirm: disenchant a few items (check that `SpellTargetItem` fires for a disenchant driven by the shuffle button's `target-item` attribute), `/reload`, and check `AHSnapshotDB.disenchants`; `/shuffledetector yields` re-records item class and level.

## Planned: more professions

The browser evaluates every crafting profession in this client (Tailoring, Leatherworking, Blacksmithing, Engineering, Enchanting, Alchemy, Mining/smelting, Cooking and First Aid). What is left:

- Confirm the addon records known recipes for every profession (only verified for Tailoring, Enchanting and Cooking); the "known only" filter falls back to showing everything for a profession with none recorded. Also confirm the shuffle button can craft recipes of other professions when their window is open.
- Gathering and processing: Herbalism, Skinning and Mining as sources of raw materials, and buying or gathering inputs versus the AH price.
- Other exit steps (for example salvage) in the same exit comparison. Prospecting and milling do not exist in this client because it has no Jewelcrafting or Inscription.
- Allow chains across professions held by different characters (craft on one, process on another), and chains where one craft feeds another profession's craft.
- Per-recipe craft times: the calculator uses 30 s unless a recipe sets `craft_seconds`. Read the cast times from the game.
