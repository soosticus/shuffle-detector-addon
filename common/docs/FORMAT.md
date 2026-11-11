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
  activePlan = { version = 1, selectedAt = <unix time>, recipe = "...", spell = <id>, item = <id>, itemName = "...",
                 makes = <n>, exit = "Vendor" | "Sell on AH",
                 reagents = { { item = <id>, qty = <n>, raw = { item = <id>, qty = <n> } }, ... },
                 estimate = { cost = <copper per craft>, income = <copper per craft> } }, -- optional
  snatcher = { [playerGUID] = { target = <finished items>, completed = <crafts>, ... } },
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
    { item = <id disenchanted>, quality = <item quality>, ilvl = <item level>, class = <item class>,
      loot = { { item = <id>, qty = <n> }, ... }, time = <unix>, complete = true,
      capture = { version = 2, target = "shuffle" | "SpellTargetItem",
                  client = { version = <client version>, build = <build>, interface = <interface>,
                             project = <project id>, realm = <realm-faction key> } } },
  },
}
```

`activePlan` is written only when the user explicitly chooses **Set active shuffle**
in the in-game browser after calculating a fully priced batch for a learned recipe.
Unknown or provisional prices cannot be activated. The selected recipe and its
finished-item batch target persist separately in `activePlan` and the character's
`snatcher` state. Loading the bundled `Plan.lua` restores `activePlan` when no
companion-generated plan assigned one. The later-loaded shuffle runtime compares
timestamps so a newer in-game choice supersedes an older generated plan, while a
newer companion-generated plan supersedes and clears the stale in-game choice.
Selecting a plan does not buy or craft: purchases still need configured limits and
a later shuffle-macro press; Auction House commodity quotes and confirmations are
separate steps. Crafting requires its own shuffle-macro press.

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

`disenchants` is recorded only when a matched player Disenchant cast succeeds,
exactly one captured target item disappears from bags, and the complete loot
snapshot is available within three seconds after success. The target is bound
at cast start, not expired by the duration of the cast. `Disenchant.lua` records
the secure shuffle button's target on its hardware press and also hooks
`SpellTargetItem` for manual targeting. Late hook delivery during the cast is
supported. Missing links/quantities and delayed bag updates are retried while the
window remains intact; clearing/closing partial loot or reaching the timeout
skips the sample and writes a diagnostic instead of recording zeroes or partial
outcomes. Repeated cast/loot notifications cannot count the same result twice.
Real client event ordering still needs in-game confirmation.

New records have `complete = true` and a `capture` block with method and available
client identity. These describe capture evidence, **not** verified baseline
accuracy. Older entries remain unchanged and have unknown capture/client
identity; do not infer their build from the current login. Raw history is still
capped at 500; versioned aggregates described below retain compatible complete
observations beyond that rollover. The
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

## Disenchant observation aggregates

`Observations.lua` stores `AHSnapshotDB.disenchantStats` separately from the raw
history and never changes the legacy samples' identity:

```
{
  version = 1, seeded = n, unversioned = n,
  clients = {
    [scopeKey] = {
      client = {version, build, interface, project, realm},
      items = {
        [itemIdentity] = {
          item, class, quality, ilvl, samples = n,
          sums = { [materialID] = <total quantity> },
          products = { [materialID] = { [otherMaterialID] = <sum of per-cast quantity products> } },
          outcomes = { ["materialID:qty,materialID:qty,..."] = <cast count> },
        },
      },
    },
  },
}
```

The scope uses the recorded client version/build/interface/project and realm/faction;
item identity uses item/class/quality/item level. Builds/realms and item-level
variants are not pooled. Sums, second/cross moments and whole-cast outcome counts
preserve measured dispersion and covariance without assuming independent Poisson
materials. Unseen rare outcomes remain unknown, not proven impossible.

On the first new capture, a missing aggregate namespace is initialized once from
fully identified, complete retained version-2 captures only (`seeded`); other
retained samples are left untouched and counted in `unversioned`. Subsequent
captures update the aggregate before the raw history rolls over. Reloading does
not reseed it. Counts predate neither this initialization nor the retained
compatible samples, so they are not lifetime totals for all historical casts.
Unique scope/item/outcome groups accumulate with observations even though raw
history is bounded.

Unknown newer/malformed aggregate formats are preserved with a diagnostic while
raw capture continues; malformed raw-history values are preserved and recording
fails explicitly. Incomplete new outcomes are never appended. The companion
still consumes raw observations only and ignores this aggregate namespace.
Neither completeness nor a large count automatically promotes observations into
a trusted baseline; the future evaluator must apply its separate evidence policy.

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
  For a verified supported single-input intermediate, its effective cap is the raw item's
  saved cap multiplied by raw quantity per intermediate. The UI shows that cap read-only;
  old saved intermediate caps are ignored while conversion is verified. A zero raw cap
  disables both purchases. Unsupported/unverified conversions keep the direct saved cap.
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

# Batch statistics

`AHSnapshotDB.batchStats = { nextId = n, characters = { [characterGUID] = { history = {...} } } }`
stores up to 200 batches per character, oldest first. `snatcher[GUID].statsId` links the active
batch; `inFlight.batch` links a purchase reservation to its original batch, and vendor
reservations now include `total` (actual bundle cost in copper).

Each history record has `id`, `recipe`, `item`, `started`, `target`, `makes`, `crafts`, `items`,
`available` (recorded output not yet sold/disenchanted), `cost`, `income`, `manualCost`,
`manualIncome`, `purchases` (units bought), `sold` (output units sold), and optional `closed`
timestamp / `incomplete` flag. Optional `estimate = {cost, income}` copies per-craft companion
cost and net exit value at batch creation. It is never counted as actual cash. Manual entries
can retain `lastAdjustment = {kind, value}` for one-step undo. A pending macro vendor sale
stores `sale = {before, gold, price, at}` until matching bag/gold changes confirm it; restored
or timed-out sales are flagged incomplete rather than inventing income.

Costs count confirmed snatcher spending in full; income counts attributed macro vendor
sales plus manual additions. Unsold AH items and disenchant loot have no realized income.
Cash net is `cost + manualCost` subtracted from `income + manualIncome`; average divides
this by newly crafted `items` (unavailable until at least one item was crafted). A closed
batch remains in history until retention removes it. The companion ignores this ledger.

Plans may include `estimate = { cost = <copper per craft>, income = <net copper per craft> }`
when the selected result has finite values for both. Old plans omit it and still work.

# Reference data

`common/data/reference.json` holds item names, vendor prices, recipes (reagents, plus optional `profession` (default Tailoring) and `makes`, the pieces one craft produces), `refined` (bolt or bar item -> raw item and quantity per piece) and average
disenchant yields. The bundled values are unverified seed data; edit them or pass an extra file
that overrides recipes by name.

# Build-time reference bundle contract

`shuffledetector.bundle` is developer tooling for the addon-only migration:

```
PYTHONPATH=companion/src python -m shuffledetector.bundle reviewed-input.json Data.lua
```

It currently supplies a validator/generator only: **no production dataset or
disenchant baseline is provided, and generated files are not yet loaded by the
addon**. The companion workflow above remains unchanged. Do not feed the
unverified `reference.json` seeds into a trusted bundle.

Schema 1 input is a JSON object with exactly these fields:

| Field | Contract |
| --- | --- |
| `schema`, `revision` | Integer `1` and a nonempty dataset revision. No generation timestamp is added, so identical inputs generate identical Lua. |
| `client` | `{flavor, interface, build}`: explicit client flavor, positive interface integer and exact build identifier. Interface alone is not evidence that another client shares the data. |
| `coverage` | Nonempty description of what is covered, missing, or uncertain. Empty model arrays mean no data, never an implicit zero yield. |
| `sources` | Array of `{id, revision, sha256, license, permission, redistributable}`. SHA256 is the lowercase 64-digit hash of reviewed source input; `permission` points to the redistribution evidence, and `redistributable` must be boolean `true`, even for exploratory data. |
| `recipes` | Array of `{spell, item, profession, makes, reagents, source, status}`. Profession is a stable ID; reagents are `{item, qty}`. Optional `name`, `skill`, `craft_seconds` and `verification`; unknown skills remain absent. These are item-producing recipes, not productless enchants. |
| `disenchant` | Array of `{class, quality, low, high, source, status}` plus exactly one of `expected` or `outcomes`, and optional `verification`. Classes 2/4, qualities 2/3/4, inclusive positive item-level bounds. |
| `exclusions` | Array of `{item, reason, source, status}` and optional `verification` for item-specific eligibility exceptions. These carry provenance too; they are not inferred from class alone. |

Every recipe, DE model and exclusion uses a declared source ID and a `status` of
`trusted` or `exploratory`. A trusted record additionally requires nonempty
`verification` describing client-specific evidence. These fields are reviewed
declarations: **the validator cannot establish redistribution rights or game
accuracy**. Neither an installed file nor a filled-in license string grants
permission. A production source must still pass the human provenance/client
review; no data is fetched automatically.

`expected` is an array of `{item, avg}` with positive finite average quantities;
it contains no invented distribution or numeric confidence interval.
`outcomes` is an array of `{probability, loot}`, with `loot = [{item, qty}, ...]`.
Each probability is positive and at most one; the sum must be one within 1e-9
roundoff, without normalization. Whole-cast loot vectors preserve correlations.
An explicit empty loot vector can represent a documented no-drop outcome, but a
model must contain some material output. Duplicate material/outcome identities,
reversed/overlapping bands within a trust level, nonfinite numbers and integers
not exactly representable in Lua are rejected. Trusted and exploratory bands can
coexist but must remain distinct in future evaluation/UI.

The generator canonicalizes row order, emits `ns.bundle`, adds a canonical-input
`content_sha256`, and derives sorted `wanted_items` from all referenced products,
reagents, DE materials and exclusions. Invalid input never replaces an existing
output file. Synthetic fixtures in `tests/test_bundle.py` exercise the contract
and generated Lua; they are not real game evidence or a distributable baseline.

## In-game price-provider contract (migration work)

`Prices.lua` is loaded for the read-only `/shuffledetector browse` preview. Its
`ns.AuctionatorQuote(itemID, "commodity")` reads the public v1 ID API on demand,
without item-info caching, disk access, refresh callbacks or synthetic stock.
The caller must establish commodity identity; gear or unspecified identity
returns unknown. Support is restricted to the tested Forever 1.60.1 builds
70862/70888, interface 16001, project 18, with Auctionator 344. User confirmation
establishes copper units for this combination; build 70888 logs establish changed
API prices after a scan without reload. Other clients/providers remain unsupported
until verified, not silently assumed compatible. A newer whole-number Auctionator
release (for example 345) reports `untested-provider-version` with
`untestedVersion`; its prices stay off unless the browser's session-only
**Preview N prices** switch calls `ns.SetUntestedProviderAllowed(true)`. Then the
status has `provisional = true`, quotes carry `provisional = true`, and the browser
labels every affected banner, row and breakdown as untested. The switch is never
saved and does not cover older releases or non-numeric versions.

`ns.PriceProviderStatus()` exposes readiness, exact detected `providerVersion`,
client identity, and a readable `detail` for version/client rejections.
Version comparisons accept only numeric/string `344` after trimming surrounding
whitespace; this does not accept a version prefix such as `344.1`. Metadata/version
errors stay visible and rejection details are logged once per distinct mismatch.

Every quote has `status`, `source`, `currency`, `item`, `identity`, and explicit
unknown `depth`, `exactness` and `ageUnits`. Supported quotes include client,
provider version and current realm/faction `scope`. A usable positive integer
copper price has `status = "estimate"` and `unit`; unknown quotes have `reason`
and no `unit`. Missing, zero, negative, fractional or nonfinite prices cannot
become free inputs. API failures are logged and returned as explicit reasons.
Optional `rawAge` retains the raw nonnegative number, without converting it to
days or asserting freshness. Age failures leave the price estimate intact with
`ageReason`. No callback, availability quantity, gear variant resolution,
disenchant model or guaranteed execution price is implied.

`Planner.lua` copies the current character's recorded item-producing recipes into
evaluation inputs, without modifying their stored tables. It exposes learned and
unlearned status separately and excludes records missing complete reagents/products.
Only recorded class-7 trade goods enter the commodity provider; gear/unknown
classes stay unavailable. Each explicit refresh takes a fresh per-item quote
snapshot; there is no per-frame evaluation or assumed callback signature.
Vendor observations are economic estimates with the existing location/discount
limitations, not a proof of current merchant access. Single-reagent preparation
alternatives require a recorded learned recipe; conflicting alternatives are not
silently chosen.

`Calculator.lua` scales a selected evaluation into shopping requirements and
expected output, or floors the number of crafts affordable within a whole-copper
budget. Unknown cost blocks budget calculation but does not prevent showing
requirements for an explicit craft count. The 100000-craft cap is explicit;
finished output over the execution limit of 100000 is flagged without clamping.
No AH quantity/stock, independent-Poisson range or DE baseline is fabricated.
`Browser.lua` keeps only transient preview state: it neither writes planner
SavedVariables nor replaces `ns.plan` or any snatcher/statistics state. Durable
selection and the centralized safe execution transition remain future work.
The preview's recipe filter distinguishes learned shuffles from unlearned patterns;
both are read-only recipe details, never action buttons. Dropdown filters keep
the no-baseline Disenchant choice disabled. Row subtitles describe why profit
cannot be calculated, while the provider banner identifies version mismatches.
