# ShuffleDetector

A WoW Classic addon that finds and runs the most profitable crafting shuffle (craft something, then disenchant it, sell it on the auction house or sell it to a vendor), priced from your [Auctionator](https://www.curseforge.com/wow/addons/auctionator) auction house scans.

- `addon/ShuffleDetector/`: the addon. It records profession skill, recipes (learned and not yet learned, with reagents), item names and vendor prices to SavedVariables, ranks shuffles in game, buys materials and runs the shuffle from one macro. It does no auction house scanning of its own.
- `tests/`: Lua test harnesses that stub the WoW API (`tests/run.sh`).
- `docs/FORMAT.md`: the SavedVariables layout.
- `CLAUDE.md`: working notes for AI assistants.

Earlier releases also had a desktop companion app. It was removed in 0.9.6; the addon now does everything it did except estimating disenchant yields, which is planned for 0.10.0.

## Install

Requires Auctionator. Download `ShuffleDetector-<version>.zip` from the [releases](https://github.com/soosticus/shuffle-detector-addon/releases) and unpack it into `Interface/AddOns` (or copy `addon/ShuffleDetector` from a checkout). Open each profession window (and visit vendors) once so the addon can record recipes and prices; `/shuffledetector browse` then ranks shuffles.

The addon asks the game for the names and vendor sell prices of every item in your recorded recipes after login (`/shuffledetector items` repeats it). Vendor buy prices still come only from visiting a vendor.

Prices: scan the auction house with Auctionator as usual. The addon reads Auctionator's lowest listing for each item in game, so no `/reload` is needed after a scan. Auctionator keeps minimum prices only, so the estimates assume any quantity can be bought at that price.

## Auctionator compatibility diagnostic

`/shuffledetector prices` records a read-only probe of the client/build, Auctionator
version and candidate public price APIs in the diagnostic log. Optional item IDs
(up to eight) choose the comparisons, for example `/shuffledetector prices 2589 2996 7054`.
Use `/shuffledetector log 80` to read the results before and after an Auctionator
scan, and compare them with Auctionator's displayed prices on the current realm.
Missing quotes and errors do not mean zero prices. The user-tested Forever
1.60.1/Auctionator 344 combination returns copper, with changed commodity quotes
after a scan without reload. On build 70888, Auctionator 345 returned 24c for 2589
and 56c for 2996, matching the subsequently saved price database. Whether the 345
probe changed without a reload, age units, and item variant behavior remain unverified.
The addon does not gate on Auctionator's version: any release that exposes
`Auctionator.API.v1` is used, and a future API break is fixed when it happens.

The local v2 probe also records the public API's raw exactness flags and DE
valuations, where available. DE values are opaque estimates: they do not supply a
loot distribution, establish correct Forever yields, or identify included fees.
Missing optional functions are logged without preventing the other comparisons.

This diagnostic does not change the loaded plan or buy anything.

## In-game rankings and calculator preview

`/shuffledetector browse` opens the in-game rankings. Open each profession window to record your recipes and visit vendors
to record their buy prices. After recording or scanning with Auctionator, click
**Refresh / search** in the preview; no `/reload` is needed for price refresh.

The browser ranks the current character's recorded item-producing recipes by
estimated profit. Use the **Profession**, **Recipes** and **Sell crafted item via**
dropdowns to filter; enter a recipe name and press Enter to search. **Learned recipes**
are shuffle previews for this character; **Unlearned patterns** compare recipes to
learn later, not actions that can craft them now. Unlearned patterns also include
recipes your other recorded characters know, and **Professions to learn** lists
only recipes of professions this character does not have, to spot a profitable
profession to pick up. For professions none of your characters has, the browser
reads every recipe the game client describes (spell IDs 1-500000) the first time
it opens, and again after a game patch; this takes a few seconds in the background,
then the list updates. It keeps only professions no character has and prints how
many recipes of your recorded professions it also found, as a check.
`/shuffledetector catalog [highest spell ID]` rescans by hand. Whether this client
describes recipes of professions nobody has is not yet confirmed; if the scan
reports none, it does not. Selecting any row only shows its
breakdown. Select a row for reagent costs, exit values, missing-price reasons and
casting-only profit/hour. The batch calculator accepts **craft counts** or a
**budget in whole copper**; it shows shopping requirements, finished output and
estimated cost/net/profit. If you have saved price limits in the shuffle window,
it also shows the batch at your limits: the most the materials cost when every
craft's reagents are bought at or under the limit (a bolt limited by its cloth
limit, as the snatcher does), the returns, and the least profit.

The browser remembers filters, search text, the previewed recipe, calculator mode
and amount separately for each character across `/reload` and logout. Reopening
it refreshes price estimates and reveals the selected recipe's page. If that
recipe no longer matches, the first matching preview is shown instead. Calculated
batches and price quotes are not saved; press **Calculate** for a fresh breakdown.

For a batch, **Material costs** lets you set an average cost per unit in whole
copper for each reagent or its recorded raw preparation material. Use **Previous
material** / **Next material** to choose an item, **Set cost** to save an
override, or **Use market** to clear it. Zero is allowed. Overrides are remembered
per item and character; they replace that item's AH/vendor estimate for the batch,
while buying a refined material and preparing it from raw still compete on cost.
The batch breakdown identifies custom prices and relevant overrides not used.
The recipe ranking and per-craft market breakdown remain based on market/vendor
estimates. Custom costs are estimates, not purchase limits or available stock;
configure the snatcher's limits separately.

For a fully priced learned recipe, **Set active shuffle** stores that recipe and its
finished-item target in the addon. It uses the calculated batch, or the amount box
(default 1 craft) if **Calculate** was not pressed. Incomplete prices and unlearned
recipes cannot be activated. The frozen plan estimate uses any custom batch costs.
This explicit button changes the active plan but does not buy or craft anything.
Purchases still require configured limits and a later shuffle-macro press; Auction
House commodity quotes and confirmations remain separate steps. Crafting still
requires its own shuffle-macro press. The active selection and batch target persist
in SavedVariables.

This slice deliberately has limits:

- AH prices are on-demand, shallow estimates (Auctionator's lowest listing) for
  recorded items priced by item ID: trade goods, potions and other consumables.
  Weapons and armor have no AH valuation, because suffix variants share an item ID.
- Unknown inputs or yields stay unknown, never free or zero. No verified
  disenchant yield table ships yet, so disenchant values are not estimated.
- Recorded vendor quotes may be stale or specific to another character's
  location/discounts. AH sales assume a 5% fee, without deposits or failed listings.
  Quantities are requirements, **not available auction stock**. Age units, depth,
  exactness and large-batch price impact remain unknown.
- Learned single-reagent preparation recipes can supply cheaper raw-material
  alternatives; their extra craft time is not included in casting-only profit/hour.
  The calculator caps at 100000 crafts and flags more than 100000 finished items;
  it does not invent a numeric DE outcome range.

Selecting a row or calculating a preview never replaces your
active plan, resets batch progress, changes purchase caps, or buys/crafts anything.
Within the browser, only **Set active shuffle** changes the plan and target.

The provider banner reports the installed Auctionator version. If Auctionator is
missing or its v1 price API is gone, the banner and diagnostic log say so and name
the detected version; recorded vendor alternatives stay visible. Unpriced rows explain the
missing input/exit instead of repeating `unknown`, and Disenchant is disabled in
the exit dropdown until a trusted model is available.

## In-game shuffle

Select and activate a fully priced shuffle and target in the browser (**Set active shuffle**). One window shows batch target/price controls, batch progress, the live shuffle steps, craftable count and crafted pieces in your bags. The next action includes purchase prices and waiting states. Drag the window to move it; its position and visibility are remembered.

Use `/shuffledetector shuffle` to toggle this combined window; `/shuffledetector snatch` is an alias, not a separate shopping window. You can put the toggle in its own macro:

```
/shuffledetector shuffle
```

This show/hide macro is separate from the action macro below. Hiding the window stops AH polling and cancels an unconfirmed quote, but does not reset saved batch settings or purchase reservations. An explicit action-macro press can restart polling while the window remains hidden.

To run the shuffle, make a macro (`/shuffledetector macro` prints it) and press it repeatedly:

```
/click ShuffleDetectorShuffleButton
```

Each craft press queues as many finished-item crafts as your materials, remaining target and current bag space allow, **leaving two general-purpose inventory slots empty**. There is no fixed item-count cap. Available room in unlocked stacks of the output also counts; specialized bag slots and space that might be freed by consuming reagents do not. Recipes making multiple items per cast must fit their entire output. If fewer than two general slots are empty, free space first. Clients without quantity-aware crafting or bag-capacity APIs still craft one at a time.

The macro waits for the entire craft queue and final bag update, then processes all finished items before starting another batch. Each disenchant press processes one piece; for a Vendor exit, open a merchant window and each press sells one stack (the tracker says "Open a vendor window to sell N" when you are out of reagents). An AH exit only prompts you to post the items yourself. If crafting is interrupted, existing finished items are processed before the next batch is recalculated. The two empty slots provide loot headroom, not a guarantee that every disenchant result will fit.

WoW doesn't let chat commands cast spells, so the macro presses an invisible secure button that picks and does the action. Presses while a cast or bag update is in progress do nothing. You can also bind a key under Key Bindings > AddOns > ShuffleDetector. The step only changes out of combat. `/shuffledetector plan` prints the loaded shuffle and the next step.

### In-game material snatcher

Set an active shuffle in the browser, then use `/shuffledetector shuffle` (or `/shuffledetector snatch`) to show the combined shuffle/batch window:

1. Enter a **finished-item target** and each purchased raw/direct reagent's **maximum unit price** (`1g 20s 5c`, or a number of copper), then click **Save limits**. Verified crafted reagents display a read-only cap derived from the raw price times the recipe's raw quantity. Zero disables the target or that reagent's purchases, including its derived intermediate. For multi-output recipes, crafts are rounded up.
2. At a merchant, press **your normal shuffle macro** to purchase one affordable batch of a matching gold-only listing, at the live reputation-adjusted price. It respects stock, bundle sizes and remaining quantities; it never buys an oversized bundle. When bag-capacity APIs are available, purchases also preserve two empty general-purpose slots and use only unlocked partial stacks. Keep pressing as bag updates arrive. Vendors are not bought from unattended. Compact material rows place price controls on the right; there are no separate vendor-buy buttons.
3. At the AH, press **the same macro** to start polling (or click **Start AH polling**). Searches rotate through outstanding reagents, at most once every three seconds, and respect the client's throttle. Once the tracker displays an offer, another macro press buys an individual auction outright, or requests a commodity quote. Commodities require a **separate press after the quote arrives** to confirm. **Buy AH offer** and **Confirm AH purchase** remain available in the panel. There is no unattended AH purchasing, or bidding below buyout.

The single-button flow uses `/click ShuffleDetectorShuffleButton` and its existing key binding. Save your target and price limits in the snatcher panel first; macro presses never save unsubmitted edits. The tracker shows the next action and price. Purchase confirmations and bag updates block further buying; existing crafted items are still processed through disenchant/vendor exit actions first. With no pending purchase, crafting from bagged materials (including raw preparation) takes priority over shopping for the rest of the batch, so shopping does not indefinitely postpone crafting. With a vendor window open, one press sells every crafted piece in your bags. Starting a craft with the AH open also starts AH polling for the rest of the batch, and while the craft casts the tracker shows the search results under "Working..."; pressing the macro then quotes, confirms or buys an offer without interrupting the craft. Collect mailed materials and open your profession before crafting. Vendor buys stop once your bags hold five stacks of that reagent (for example 100 Coarse Thread), leaving room for AH materials; the next vendor visit tops it up. One press buys all of it, split into one-stack purchases because the game limits each purchase to a stack; if only part arrives (for example, bags fill up), that part is recorded and the rest can be bought again. When the whole batch costs more than the gold you carry, AH and vendor offers shrink to what you can afford instead of disappearing. While AH polling runs, the tracker shows what the last search found for each material (cheapest price against your limit, not enough gold, none listed, your own listing in the way, or the AH throttling searches), and `/shuffledetector log` records each change. Uncertain AH purchases must still be resolved explicitly in the panel, never by repeatedly pressing the macro. Vendor purchases settle themselves from the bag count about a second after a game error (such as "Inventory is full"), after 15 seconds without a bag update, or after `/reload`; a buy that never reached your bags is released so the macro can continue.

Only **Save limits** and **More controls** are normally visible. Expand **More controls**
to access AH polling/buying, **New batch**, **Analytics** and purchase/mail reconciliation;
**Less controls** collapses them again. Hiding these controls does not stop polling or
change purchase reservations. The normal shuffle macro still drives all purchases.

Requirements subtract bag stock, completed crafts and this snatcher's purchases awaiting mail collection. The shuffle macro stops crafting at the batch target but still processes crafted items through its exit step. **New batch** resets craft progress, not the awaiting-mail ledger. Targets, progress and prices are saved per character; changing the recipe disables the old target. Bank stock, existing finished items and other addons' purchases are not included. Single-step raw-material preparation is described below.

#### Raw cloth versus bolts, and automatic preparation

For Linen Bags, the snatcher can buy **Linen Cloth or Bolts of Linen Cloth**, whichever eligible live offer has the lower average cost per produced bolt: a bolt requires two linen cloth. Open this character's Tailoring window once to record the learned bolt recipe, then open the snatcher and set **only the Linen Cloth price ceiling**. The bolt ceiling is displayed read-only as **2 x the cloth ceiling**; for example, 30c cloth allows bolts up to 60c. Old saved bolt ceilings are ignored while the verified conversion is available. A zero cloth ceiling disables both cloth and bolt purchases, but cloth already owned can still be used. The same rule covers supported single-input bars/bolts using their own conversion quantity. Unsupported or unverified conversions still use a direct price input. The conversion comes from the character's recorded recipes.

The snatcher searches both enabled alternatives before offering either one, checks their freshness again when buying, and compares the quoted cost again before confirming a commodity purchase. Existing bolts and cloth (including purchases in mail or in flight) cover the **same** requirement, so it does not buy a full batch of both. Partial cloth stacks are included; purchases must complete whole bolts without exceeding the raw shortfall. Vendor alternatives use the same converted-cost comparison between eligible listings at the open merchant.

The cloth row's **Raw need** is for the **unfilled** bolts after existing/reserved
bolts are deducted; **buy** also subtracts cloth already held or reserved. For
example, six required bolts, one existing bolt and three cloth show raw need 10
and buy 7. Both rows refresh after bag updates, including newly crafted bolts.

With a snatcher target enabled, **the normal shuffle macro automatically prepares bolts when the bag recipe is missing them**. Collect the cloth and open Tailoring, then press `/click ShuffleDetectorShuffleButton`: for stackable intermediates that consume multiple raw items per output, one press queues all missing bolts for the remaining batch that your bagged cloth can make. Existing bolts and reserved purchases are deducted; cloth still in mail cannot be crafted. The tracker shows the preparation quantity. Further presses wait for the entire queue and its final bag update, then craft bags in space-limited batches as described above; bolt casts do not advance the finished-bag counter. Interrupting the queue lets the next press recalculate what remains. Nonstackable or uncached outputs, and clients without the modern quantity-aware crafting API, still prepare one intermediate per press. This uses the game's crafting queue, not unattended macro presses.

Supported conversions have one raw reagent and produce one intermediate per cast, with a spell recorded as learned on this character. This also covers similar single-input bars/bolts. Multi-step chains, multi-output intermediate recipes, and raw materials shared by multiple direct requirements are not expanded; the panel explains when to buy an intermediate directly. Missing or mismatched recipe records require reopening the profession window. Prices compare available batches, not a globally optimized multi-auction crafting chain.

Offers expire after ten seconds. Live results are checked again before buying; quotes exceeding the cap, available gold or displayed total are rejected. Commodity result tiers must be within the unit cap, and the server quote must also fit the capped total cost; a quote does not expose its individual price tiers. Individual-auction stacks cannot exceed the outstanding quantity. Polling stops when the panel/AH closes, combat begins, or another addon searches; an explicit macro press at the AH can restart it using saved limits, even with the panel hidden. Avoid using Auctionator's shopping/scanning at the same time. The snatcher conservatively ignores commodity results containing your own/account auctions.

Unconfirmed purchases remain reserved across `/reload` and block further purchases. Vendor purchases are settled automatically from your bag count. For AH purchases, after checking bags **and mail**, use **Resolve uncertain purchase** to identify whether the materials remain in mail or the reservation can be released. Mail collection is detected after normal attachment/auto-loot actions; if materials were collected with this addon disabled, after a slow mail response, or through another collection method, use **Reconcile collected mail** only after collecting **all** purchased materials. Never clear reservations just to retry a purchase whose outcome is unknown.

This first version has a deterministic Lua API test harness, but real Forever-client purchases and UI/protected-action behavior still need in-game confirmation. Start with a small target and inexpensive materials. Check `/shuffledetector log` for diagnostics.

### Batch statistics and history

With a saved, nonzero batch target, the combined in-game window shows **confirmed spending,
income, cash net and average cash net per newly crafted item**. Snatcher purchases are charged
only after confirmation, including raw cloth and vendor bundles. Shuffle-macro vendor sales
require matching output loss and gold gain and are limited to this batch's recorded output.
Disenchanting removes finished stock but **does not count unsold loot as income**. Ordinary
AH sales, unrelated merchant sales and general gold changes are not automatically attributed.

A shuffle set in the browser carries its **per-craft estimated
cost and net exit value**, frozen when a statistics batch starts. The window shows, separately
from actual cash, the estimate for the **whole batch target**: reagents costed at your saved
price limits (the most the snatcher pays, so cost is "up to" and profit "at least"; a refined
reagent such as a bolt is costed at its raw material's limit), or at the frozen market cost
while any reagent has no limit, and the exit value times the batch's crafts.
These are scan-based estimates, including a 5% AH fee; not realized sales.
Existing materials are not free economically, but their historical purchase cost is unknown.
Actual cash net charges the full confirmed purchase (including leftovers), so it is not
an inventory-adjusted profit margin and can stay negative until outputs are sold.

Open **Analytics** from the batch window, `/shuffledetector stats` (alias `analytics`), or
the **ShuffleDetector** AddOn settings entry when the client's Settings API is available.
The separate movable window shows retained-history totals, latest batch results, paired
cost/income bars and a cumulative cash-net chart for up to 16 displayed batches.
**Older batches** / **Newer batches** browse retained history. History is per
character and persists across `/reload`/logout; at most **200 batches** are retained, so
totals are for retained history, not lifetime earnings. The newest batch stays active until
**New batch** or a recipe change closes it; reaching the craft target alone does not close
it because selling may still be in progress.

In Analytics, enter verified **untracked** expenses or net AH/loot sale proceeds in g/s/c
and use **Add cost** / **Add income**. Leave **Batch ID** blank for the active batch or enter
a displayed historical ID to attribute later AH proceeds to a closed batch. Do not enter
amounts already tracked automatically. **Undo last entry** reverses the last manual entry
in the selected batch. An unconfirmed
vendor sale is flagged incomplete and may require a verified manual income entry; an
unresolved snatcher purchase still uses the existing reconciliation workflow. Statistics
begin with this version and do not reconstruct old crafting or purchases.

These charts show measured cash-flow trends, **not proof that the addon increased income**:
that claim would require comparable activity without the addon. Confirm statistics and Settings integration in game using a
small inexpensive batch before relying on the totals.

Click, cast and game-error diagnostics are not printed to chat; they go to a hidden log. `/shuffledetector log` shows the last lines (`log <n>`, `log clear`), and `/shuffledetector log echo` also prints new lines live while you debug a macro.

## License

[MIT](LICENSE).

## Releases

Pushing a tag like `v0.3.0` runs `.github/workflows/release.yml`, which runs the tests, replaces the `@project-version@` placeholder in the addon `.toc` with the tag (without the leading `v`), zips the addon and publishes a GitHub Release with `release-notes/<tag>.md` as its body.
