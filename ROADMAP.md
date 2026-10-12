# Roadmap

Open items only; finished work is removed. Release notes are generated from commit history by the release workflow.

## Open items

- Handle vendor faction/location restrictions.
- Confirm the AH tab and recipe capture (`/shuffledetector recipes`) in the Forever client. Tailoring recipes were not being recorded for the main character, so the "known recipes only" filter falls back to showing everything; if `/shuffledetector recipes` still reports 0 after opening the Tailoring window and `/reload`, the recipe capture needs a fix for the Forever API. Enchanting (craft frame) recipes are not read by the addon. Step 1 of the data plan below depends on this working.
- Confirm in game that the fast-press gating no longer repeats a craft or disenchant step.
- Shuffle follow-ups: take the craft count or budget from the calculator, and steps beyond craft/disenchant (for example vendor or AH listing) now that the calculator can name them.
- Calculator follow-ups: model price impact when buying or selling large quantities (walk the sell side of the order book), and offer a "number of disenchants" target. Use the observed disenchant results (data plan step 3) for the range instead of Poisson once there are enough samples.
- Check that pushing the re-pointed `v0.2.4a` tag after the history rewrite did not start an unwanted release run (`release.yml` triggers on `v*` tags).

## Planned: a permitted source for recipe, price and yield data

All Wowhead scraping, data and code has been removed (its terms appear to forbid scraping and it risked an IP block). The scraper, its generated `wowhead.json` and its page cache are gone from the working tree, history (rewritten and force-pushed 2026-10-11; the repo is private) and the local cache. The companion now only has the small hand-written seed data in `common/data/reference.json` (mostly Tailoring).

Rule: never scrape Wowhead or any other site against its terms. Check the terms before using any source, and keep end users from downloading anything from a third-party site themselves.

The new data keeps the same output shape (`items`, `vendor`, `vendor_sell`, `recipes` with `profession`, `makes`, `reagents`, `yields`, `skill`, `refined`) so the calculator does not change; `load_reference` merges the seed file with an extra file. Derive `refined` (single-input intermediates such as bolts and bars that are reagents elsewhere) from the recipes.

The plan is three steps, in this order:

1. **The addon records what the game already knows (in progress).** For the character's own professions: recipes with their reagents and the pieces made (profession API), item names and vendor sell prices (`GetItemInfo`), written to SavedVariables and read by the companion. No external source is needed for recipes the user already knows. Status and design notes are under "Step 1 status" below.
2. **wago.tools client tables for recipes the character does not know ("recipes to acquire") and vendor buy prices.** A one-off build script converts the tables to the `reference.json` shape and the result is committed, so end users never download from wago.tools. Before building it: check wago.tools' terms (data use and republishing) and whether it has the Forever (Interface 16001) build, since the tables are per game version. Relevant tables: `SkillLineAbility` (profession to spell, skill levels), `SpellReagents`, `SpellEffect` (created item and quantity), `ItemSparse` (`BuyPrice`, `SellPrice`). Table and column names are from memory of the DB2 layout and are not yet verified against this client.
3. **Disenchant yields from observation.** The addon logs every disenchant result (item level, quality, what dropped) to SavedVariables. The companion shows observed averages and sample counts, with a small hand-written approximate table as the fallback until enough samples exist. `ItemDisenchantLoot` in the client tables only maps items to loot IDs; the loot itself is server-side, so observation is the only permitted source of rates. No copying from Wowhead or other crowdsourced sites without checking terms.

Suggestions from an outside (Gemini) answer that must not be used as stated: a "Copy table" button on wago.tools and ForeverDB.net as a data source are unverified or against the spirit of the Wowhead removal, so check terms first. It also named the wrong tables (`ItemModifiedAppearance`, `ItemEffect`); use the ones above.

### Step 1 status

Addon (`ShuffleDetector.lua`): recipes were recorded as `{name, spell}` (modern API) or `{name, item, difficulty}` (classic API) with no reagents. To do: for each recipe also record the reagent item IDs and counts and the item made with its count, record `GetItemInfo` names and vendor sell prices for every item seen (reagents, products, scanned items), and keep it in a new top-level SavedVariables table (`items`) rather than per character. Companion: `load_scan_data` currently reads only `scans` and `characters`; it needs to read the new fields, and `load_reference` should merge them under the seed data (seed and the later wago.tools file override observed data by lowercase recipe name). Update `common/docs/FORMAT.md` for every new field.

## Planned: faster and automatic reference data builds

Only relevant to the wago.tools build (step 2); the addon-recorded data needs none of this.

- Incremental builds: the client tables change only with game patches and the Classic data is effectively static, so the build script should be re-run only on a new client build number; record the build number in the output and skip when unchanged.
- Scheduled check: a GitHub Actions workflow, weekly plus manual trigger, that compares the build number and, when it changed, rebuilds and publishes the data file as a release asset or a commit. Test one manual run first, since some sites block GitHub's runner IPs. Only do this if the source's terms allow automated downloads.
- Companion: add a "download latest data" option that fetches the published bundle from our own release, so end users never download from a third-party site.
- Confirm the source's terms allow republishing the derived bundle before making the repo public.

## Planned: CurseForge release

Prepare the addon for CurseForge. Check CurseForge's current requirements before submitting, since they change.

- Confirm CurseForge lists the "Forever" client (Interface 16001) as a game version. If not, decide whether to publish under the closest supported version or stay on GitHub releases only.
- Create the project: name, short summary, a full description (what the addon does, that the companion app is a separate GitHub download, how to run the macro), category, license (MIT, already in `LICENSE`), and screenshots of the tracker and the AH tab.
- Icon: a proper square project logo (CurseForge asks for a 400x400 PNG or similar; check the current size limit), plus an optional in-game `## IconTexture` for the addon list. Keep the source image in the repo.
- Packaging: add a `.pkgmeta` (package-as `ShuffleDetector`, ignore dev files) and publish through the BigWigs packager from the release workflow, using a CurseForge API token stored as a repo secret. The zip needs a single top-level `ShuffleDetector` folder whose `.toc` matches it.
- `.toc` updates: add `## X-Curse-Project-ID`, refresh `## Notes` (it still describes only scanning), and consider `## Category` and `## IconTexture`. Keep `## Interface` in step with the supported client.
- Ship a placeholder `Plan.lua` in the package so the `.toc` loads cleanly, and make sure a CurseForge update does not overwrite a user's generated plan, or tell users to resend it after an update.
- Content rules: no bundled executables or the companion app inside the addon zip (link to the GitHub release instead), and credit any libraries. Add a changelog (the packager can generate one from commits).
- Decide on a version scheme and release process (tag `v*`, then upload) and document it in the README.

## Planned: more professions

The companion evaluates every crafting profession in this client (Tailoring, Leatherworking, Blacksmithing, Engineering, Enchanting, Alchemy, Mining/smelting, Cooking and First Aid), using each profession's own skill and known recipes from the scan. Recipe data for them comes from the data plan above (step 1 for known recipes, step 2 for the rest). What is left:

- Confirm the addon records known recipes for every profession (it was only verified for Tailoring); the "known only" filter falls back to showing everything for a profession with none recorded. Also confirm the shuffle button can craft recipes of other professions when their window is open.
- Gathering and processing: Herbalism, Skinning and Mining as sources of raw materials, and buying or gathering inputs versus the AH price.
- Other exit steps (for example salvage) in the same exit comparison. Prospecting and milling do not exist in this client because it has no Jewelcrafting or Inscription.
- Allow chains across professions held by different characters (craft on one, process on another), and chains where one craft feeds another profession's craft.
- Per-recipe craft times: the calculator uses 30 s unless a recipe sets `craft_seconds`. Read the cast times from the game (profession API) in step 1 if it exposes them, otherwise from the client tables in step 2.
