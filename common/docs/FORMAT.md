# SavedVariables format

The addon writes `AHSnapshotDB` to `WTF/Account/<acct>/SavedVariables/ShuffleDetector.lua`.
The companion app only reads this file. Prices are in copper.

```lua
AHSnapshotDB = {
  version = 1,
  scans = {
    ["Realm-Faction"] = {
      time = <unix>, listings = <n>,
      source = "scan" | "auctionator",   -- optional, default "scan"
      shallow = true,                    -- optional; min prices only (no depth)
      items = { [itemID] = { min = <copper>, qty = <total>, prices = { {unitPrice, qty}, ... } } },
    },
  },
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
  items = { [itemID] = { name = "Linen Cloth", sell = <vendor sell price, copper> } },  -- from GetItemInfo
  vendor = { [itemID] = <copper to buy one from a vendor> },  -- from the merchant window, gold-only items
  disenchants = {   -- one entry per successful Disenchant cast, oldest first, capped at 500
    { item = <id disenchanted>, quality = <item quality>, ilvl = <item level>,
      loot = { { item = <id>, qty = <n> }, ... }, time = <unix> },
  },
  deyields = {   -- expected disenchant results from Auctionator's in-game table, by disenchanted item id
    [itemID] = { quality = <item quality>, ilvl = <item level>, yields = { { item = <id>, avg = <expected count> }, ... } },
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

`deyields` is computed by `Yields.lua` (at login after a delay, and by `/shuffledetector yields`) from
the Auctionator addon's own disenchant table (`Auctionator.Constants.DisenchantingProbability`, keyed by
item class and quality, with item level ranges): for every recorded armor or weapon item the expected
count of each result is the sum of `chance * count`. Nothing is downloaded and no site is involved; it
needs Auctionator installed and loaded, and is left out (with a line in the hidden log) otherwise. The
companion (`ScanData.auctionator_yields`) uses it in place of the bundled `yields` and marks the recipe
`yield_source = "Auctionator"`. Precedence: observed disenchants, then Auctionator, then the bundled seed.

`prices` holds the cheapest 40 listings sorted ascending, used to cost bulk purchases.
Shallow scans (imported from Auctionator) carry one `{min, 1}` entry per item; the companion
treats them as unlimited quantity at the minimum price. The addon also stores UI state
(`shuffleTracker`, `shuffleTrackerShown`, `logEcho`) and a diagnostic ring buffer `log` (up to 300
`"HH:MM:SS message"` strings about button clicks, casts and game errors) in the same table; the companion
ignores them. `/shuffledetector log` prints the buffer.

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
    exit = "Disenchant",             -- or "Sell on AH" / "Vendor" / "" (craft only)
    reagents = { { item = 4305, qty = 4 }, ... },
}
```

The shuffle runs one step per press of a macro (`/click ShuffleDetectorShuffleButton`)
or the "Next shuffle step" key binding: disenchant a crafted piece in the bags if the exit is
Disenchant, otherwise craft the next one, until the reagents run out. A tracker frame
(`/shuffledetector shuffle` to show or hide) highlights the current step. The secure button is
invisible and chooses the step as it is clicked, because chat commands cannot cast.

# Reference data

`common/data/reference.json` holds item names, vendor prices, recipes (reagents, plus optional `profession` (default Tailoring) and `makes`, the pieces one craft produces), `refined` (bolt or bar item -> raw item and quantity per piece) and average
disenchant yields. The bundled values are unverified seed data; edit them or pass an extra file
that overrides recipes by name.
