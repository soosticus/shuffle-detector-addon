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
      professions = { Tailoring = { skill = n, max = n, recipes = { { name, item, difficulty }, ... } } },
    },
  },
}
```

`prices` holds the cheapest 40 listings sorted ascending, used to cost bulk purchases.
Shallow scans (imported from Auctionator) carry one `{min, 1}` entry per item; the companion
treats them as unlimited quantity at the minimum price. The addon also stores UI state
(`shuffleButton`, `shuffleButtonShown`) in the same table; the companion ignores it.

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

The shuffle button (`/shuffledetector shuffle`, or the "Next shuffle step" key binding) runs one
step per press: disenchant a crafted piece in the bags if the exit is Disenchant, otherwise craft
the next one, until the reagents run out.

# Reference data

`common/data/reference.json` holds item names, vendor prices, recipes (reagents) and average
disenchant yields. The bundled values are unverified seed data; edit them or pass an extra file
that overrides recipes by name.
