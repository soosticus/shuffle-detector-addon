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
      } } },
    },
  },
  items = { [itemID] = { name = "Linen Cloth", sell = <vendor sell price, copper> } },  -- from GetItemInfo
}
```

Recipes are recorded for the professions a character has, as the game's profession window reports
them; `reagents` (basic reagents only, no optional or finishing slots), `item`, `makes` and `spell`
are present when the game's API supplied them. `items` holds the name and vendor sell price of every
reagent and product of those recipes. The companion layers both over the bundled reference data
(`Reference.with_observed`): recorded names and sell prices replace the bundled ones, and recorded
recipes replace the bundled recipe of the same name but keep its skill, yields and source. Recipes
without bundled yields can still be sold on the AH or to a vendor. `refined` entries (bolts, bars) are
derived from recipes with a single reagent whose product is a reagent elsewhere.

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
