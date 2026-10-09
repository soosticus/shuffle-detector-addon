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
treats them as unlimited quantity at the minimum price.

# Reference data

`common/data/reference.json` holds item names, vendor prices, recipes (reagents) and average
disenchant yields. The bundled values are unverified seed data; edit them or pass an extra file
that overrides recipes by name.
