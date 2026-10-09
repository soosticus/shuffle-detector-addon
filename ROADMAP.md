# Future considerations

## Done: Wowhead resolver (tailoring)

`File > Update recipes & yields from Wowhead...` (or `run.cmd --update-wowhead`) writes `common/data/wowhead.json`, which overlays the seed data. Still to do: other professions, and layering observed in-game disenchant results from the addon on top of the Wowhead rates.

## External data resolver (remaining ideas)

Add an optional resolver layer with a local on-disk cache to discover recipes and resolve item IDs/names, instead of relying only on the hand-maintained `common/data/reference.json`. Anything it can't verify stays flagged as unverified.

Source priority:

1. **The addon itself (preferred)** - export item names/IDs (`GetItemInfo`), known recipes, and recipe reagents/results (trade skill APIs) alongside prices. Works for any client version, including WoW Forever. Needs an in-game check that the Forever client exposes the same trade skill APIs as Classic Era.
2. **Blizzard Game Data API** (developer.blizzard.com; replaces the retired Community API) - official; items, professions and recipes. Needs a per-user client ID/secret. Unknown whether a WoW Forever namespace exists (Classic variants have their own). Does not appear to expose disenchant loot tables, and auction data is not real-time.
3. **Wowhead** - no official API; tooltip/XML endpoints can resolve items, and page data is the practical source for disenchant yield percentages. Fragile and likely against its terms, so keep it optional, cached, rate-limited, with a clear user agent.
4. **Data-mined tables** (e.g. wago.tools exports) - recipes/reagents per build; disenchant loot tables still need a community source.

Possible UI: a "refresh reference data" action.
