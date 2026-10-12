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
are included in what the game shows) and replaces the bundled vendor buy price.

`disenchants` is recorded whenever a Disenchant cast succeeds and a loot window follows within a few
seconds (`Disenchant.lua`, which hooks `SpellTargetItem` to see what item the cast targeted). The
companion averages the loot per disenchant by the disenchanted item id (`data_loader.observed_yields`)
and, once any samples exist, uses that average and the sample count (`recipe["yield_samples"]`) in place
of a recipe's bundled `yields` for its crafted item.

`prices` holds the cheapest 40 listings sorted ascending, used to cost bulk purchases.
Shallow scans (imported from Auctionator) carry one `{min, 1}` entry per item; the companion
treats them as unlimited quantity at the minimum price. The addon also stores UI state
(`shuffleTracker`, `shuffleTrackerShown`) in the same table; the companion ignores it.

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
