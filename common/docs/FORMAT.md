# SavedVariables format

The addon writes `AHSnapshotDB` to `WTF/Account/<acct>/SavedVariables/ShuffleDetector.lua`.
The companion app only reads this file. Prices are in copper.

Prices are not in this file. They come from Auctionator's own SavedVariables file, `Auctionator.lua` in the
same folder: `AUCTIONATOR_PRICE_DATABASE` holds one CBOR blob per realm key (for example `ClassicBetaPvE2`) plus a
`__dbversion`; `auctionator.py` decodes it. Each item key is `"<itemID>"` or, for gear, `"g:<itemID>:<ilvl>"`, and
maps to `{ m = <last seen minimum price>, h = {day = highest low}, l = {day = lowest low}, a = {day = quantity} }`
with days counted from 2020-01-01 local midnight. The companion keeps the cheapest `m` per item id, treats it as
buyable in any quantity ("shallow"), and dates the realm by the newest day in `h`. Older versions of this addon
saved a copy in a `scans` table; the addon deletes it on load and the companion ignores it.

```lua
AHSnapshotDB = {
  version = 1,
  characters = {
    ["Name-Realm-Faction"] = {
      professions = { Tailoring = { skill = n, max = n, recipes = {
        { name = "Bolt of Linen Cloth", spell = <id>, item = <id made>, makes = <n, only if > 1>,
          difficulty = "optimal" | ...,   -- classic API only
          reagents = { { item = <id>, qty = <n> }, ... } },
        ...
      }, available = {    -- recipes in the window the character has not learned (same fields, plus:)
        { name = "...", spell = <id>, item = <id>, reagents = { ... },
          trivial = <skill at which it stops giving skill-ups>, source = "<where to learn it, if the API gives it>" },
      } } },
    },
  },
  items = { [itemID] = { name = "Linen Cloth", sell = <vendor sell price, copper>,
                         class = <item class id>, quality = <rarity id>, ilvl = <base item level> } },  -- from GetItemInfo
  vendor = { [itemID] = <copper to buy one from a vendor> },  -- from the merchant window, gold-only items
  disenchants = {   -- one entry per successful Disenchant cast, oldest first, capped at 500
    { item = <id disenchanted>, quality = <item quality>, ilvl = <item level>,
      loot = { { item = <id>, qty = <n> }, ... }, time = <unix> },
  },
}
```

Recipes are recorded for the professions a character has, as the game's profession window reports
them; `reagents` (basic reagents only, no optional or finishing slots), `item`, `makes` and `spell`
are present when the game's API supplied them. `items` holds the name and vendor sell price of every
reagent and product of those recipes. The companion layers both over the bundled reference data
(`Reference.with_observed`): recorded names and sell prices replace the bundled ones, and recorded
recipes replace the bundled recipe of the same name but keep its skill, yields and source. Recipes
without bundled yields can still be sold on the AH or to a vendor. `refined` entries (bolts, bars) are
derived from recipes with a single reagent whose product is a reagent elsewhere. `available` recipes
add recipes no character knows (a recipe the character knows always wins); they have no `skill`, so
their status is "unknown" until a skill requirement is available.

`vendor` is recorded whenever a merchant window is opened (price per single item; reputation discounts
are included in what the game shows) and replaces the bundled vendor buy price. Only unlimited-stock
listings count (as in Auctionator): a limited-stock listing is not recorded, and drops an existing
entry for that item. The game has no bulk query for buy prices, so they fill in as vendors are visited.

`disenchants` is recorded whenever a Disenchant cast succeeds and a loot window follows within a few
seconds (`Disenchant.lua`, which hooks `SpellTargetItem` to see what item the cast targeted). The
companion averages the loot per disenchant by the disenchanted item id (`data_loader.observed_yields`)
and, once any samples exist, uses that average and the sample count (`recipe["yield_samples"]`) in place
of a recipe's bundled `yields` for its crafted item.

`class`, `quality` and `ilvl` in `items` let the companion look up disenchant yields without any web data:
Auctionator ships a table of disenchant results (`Auctionator/Source_Classic/Enchant/DisenchantingProbabilities.lua`,
entries `{lowIlvl, highIlvl, pct, count, itemID, pct, count, itemID, ...}` per item class and quality) but the
game only loads it for the "classic" game type, not this client, so `deyields.py` reads that file from the
AddOns folder next to the SavedVariables (`<flavor>/WTF/Account/<acct>/SavedVariables/..` to
`<flavor>/Interface/AddOns/Auctionator/..`). The expected count of each result is the sum of `pct/100*count`
over the entry matching the item's level. The companion uses it (`ScanData.auctionator_yields`) in place of
the bundled `yields` and marks the recipe `yield_source = "Auctionator"`. Precedence: observed disenchants,
then Auctionator, then the bundled seed. Entries recorded by older versions get these fields after
`/shuffledetector yields` (or the next login) and a `/reload`.

The addon also stores UI state
(`shuffleTracker`, `shuffleTrackerShown`, `logEcho`) and a diagnostic ring buffer `log` (up to 300
`"HH:MM:SS message"` strings about button clicks, casts and game errors) in the same table; the companion
ignores them. `/shuffledetector log` prints the buffer.
`shuffleTracker` (point, relPoint, x, y) and `shuffleTrackerShown` now control the single combined
batch/shuffle window; existing standalone-tracker positions and visibility are reused.

# Item list (companion -> addon)

The vendor sell price and name of any item are in the game's own item cache, so the addon can fetch
them for items it has never seen. The companion writes
`Interface/AddOns/ShuffleDetector/ItemList.lua` (`ns.wantedItems = { id, id, ... }`, every reagent,
product, disenchant yield and refined raw of the recipes it knows, including ones read from the
game's files with `--local-recipes`) with `shuffledetector --send-items`. After `/reload` the addon
asks the game for the ids not yet in `items`, in batches of 40 per second, starting 5 seconds after
login (or run `/shuffledetector items`), and records the answers in `items`. Ids the game never
answers for (about 10% of a list built from the game's files, mostly ids that are not items in this
client) are stored in `unanswered = { [itemID] = true }` and skipped at login; the slash command retries
them. Addon updates keep an existing `ItemList.lua`.

# Shuffle plan (companion -> addon)

The game rewrites SavedVariables on `/reload` and logout, so the companion cannot hand data to
the addon that way. Instead it writes `Interface/AddOns/ShuffleDetector/Plan.lua`, which the
addon loads on `/reload`. Addon updates keep an existing `Plan.lua`.

```lua
local _, ns = ...
ns.plan = {
    version = 1,
    generated = <unix>,
    recipe = "Silk Headband",        -- crafting spell name
    spell = 8774, item = 7054,       -- optional ids; item identifies the crafted piece in bags
    itemName = "Silk Headband",      -- optional; used when item is absent
    makes = 1,                      -- optional output items per craft; defaults to 1
    exit = "Disenchant",             -- or "Sell on AH" / "Vendor" / "" (craft only)
    reagents = { { item = 4305, qty = 4 }, ... },
}
```

The shuffle runs one step per press of a macro (`/click ShuffleDetectorShuffleButton`)
or the "Next shuffle step" key binding: drain crafted pieces through Disenchant or Vendor
exit presses, otherwise queue the crafts that fit available materials, remaining target
and bag output capacity while reserving two empty general-purpose bag slots. Existing
unlocked output stacks contribute space; specialized empty slots and future reagent
consumption do not. Multi-output recipes use `makes` to bound whole casts. The queue stays
locked until completion or interruption; every successful main-recipe cast increments
`completed`. Legacy crafting/bag APIs fall back to one craft per press. A tracker frame
(`/shuffledetector shuffle` to show or hide) highlights the current step. The secure button is
invisible and chooses the step as it is clicked, because chat commands cannot cast.

A reagent can also include `raw = { item = 2589, qty = 2 }` (for reagent item 2996, Bolt of
Linen Cloth): raw item ID and raw units per intermediate. The companion exports this from
the calculator's existing refinement metadata, regardless of which source was cheapest in
the saved scan. The addon checks it against a learned single-input, single-output recipe
recorded on the current character; old plans without the field can use recorded recipes too.
Raw bag/mail/in-flight stock covers the intermediate requirement rather than creating a second
independent shopping target. A macro press can craft that intermediate before the main recipe;
stackable intermediates consuming multiple raw items per output use the modern crafting queue
for the remaining batch shortfall, limited to raw materials in bags. The button stays locked
until the queue completes or is interrupted. Other intermediates and the legacy spell action
remain one cast per press; only casts of the main recipe advance `completed`.

# In-game shopping state

`/shuffledetector snatch` uses the loaded plan's direct reagents, `spell`, `item`, and optional
`makes`. Both IDs are required. It stores `AHSnapshotDB.snatcher[characterGUID]`:

- `recipe`: a fingerprint of the spell, output item, output count and reagents. A changed recipe
  resets `target` and `completed`, but keeps item price limits and outstanding purchases.
- `target`: newly crafted finished items for the batch (0 disables it; maximum 100000).
- `completed`: successful casts of that recipe since the last "New batch".
- `prices[itemID]`: maximum purchase unit price in copper; 0 disables purchasing.
- `awaiting[itemID]`: confirmed AH quantities purchased by the snatcher but not yet collected.
- `bags[itemID]`: last observed bag count used to reconcile normal mail collection.
- `inFlight`: an unresolved purchase reservation (`item`, `qty`, `kind`, `at`, plus auction key,
  auction ID and/or quoted `total`, or `vendor`/`before` for a merchant purchase). It is saved
  before a merchant purchase or AH buyout/quote confirmation. A
  reload restores it as `uncertain`; subsequent purchases remain blocked until reconciled.

Polling, offers and commodity quotes are not persisted. The combined panel's position and
visibility use the existing `shuffleTracker`/`shuffleTrackerShown` UI fields. Polling uses live
`C_AuctionHouse` search results, not Auctionator's saved minimum prices. The companion ignores
shopping state. The snatcher never writes the selected `Plan.lua`.

The shuffle button also dispatches vendor buys, AH polling, buyouts and commodity
quote/confirmation steps through the same shopping state and checks as the panel. Each
purchase action requires a hardware press; quotes need a later confirmation press.
The macro uses saved limits only. Its tracker shows purchase prices and waiting/mail
states; unresolved reservations must be reconciled in the panel.
`/shuffledetector shuffle` and `/shuffledetector snatch` toggle that same window, containing
both batch/price controls and the live shuffle status. The secure action button remains
independent of window visibility.

# Reference data

`common/data/reference.json` holds item names, vendor prices, recipes (reagents, plus optional `profession` (default Tailoring) and `makes`, the pieces one craft produces), `refined` (bolt or bar item -> raw item and quantity per piece) and average
disenchant yields. The bundled values are unverified seed data; edit them or pass an extra file
that overrides recipes by name.
