# Roadmap

Open items only; finished work is removed. Release notes are generated from commit history by the release workflow.

## Open items

- Layer observed in-game disenchant results from the addon on top of the Wowhead yield rates.
- Handle vendor faction/location restrictions.
- Confirm the AH tab and recipe capture (`/shuffledetector recipes`) in the Forever client. Tailoring recipes were not being recorded for the main character, so the "known recipes only" filter falls back to showing everything; if `/shuffledetector recipes` still reports 0 after opening the Tailoring window and `/reload`, the recipe capture needs a fix for the Forever API. Enchanting (craft frame) recipes are not read by the addon.
- Confirm the in-game shuffle disenchant step in the Forever client: the `/cast Disenchant` + `/use <item name>` macro. Crafting is confirmed working through `C_TradeSkillUI.CraftRecipe` (the profession window must be open); the macro and invisible button also work. Then remove the per-press chat lines (`next:` and `click:`) or put them behind a debug option.
- Shuffle follow-ups: take the craft count or budget from the calculator, and steps beyond craft/disenchant (for example vendor or AH listing) now that the calculator can name them.
- Calculator follow-ups: model price impact when buying or selling large quantities (walk the sell side of the order book), use observed in-game disenchant results instead of Poisson for the range, and offer a "number of disenchants" target.

## Planned: more professions

Go beyond Tailoring -> Enchanting and consider every profession the scanned characters actually have. The addon already records each character's professions and known recipes, so the companion should read that list and evaluate shuffles for all of them, not just Tailoring.

- Generalize `calc.py` from the hard-coded Tailoring-only known-recipe check to any profession's recipes, with the character filter using whichever professions are present in the scan.
- Extend the Wowhead resolver to fetch recipes, reagents, vendor prices and yields for the other crafting professions (Blacksmithing, Leatherworking, Engineering, Alchemy, Jewelcrafting, Inscription, Cooking, and others available in the client), and for the gathering and processing steps (Mining/smelting, Herbalism/milling, Skinning, prospecting).
- Support other exit steps beyond disenchanting, such as prospecting, milling and salvage, in the same exit comparison.
- Allow chains across professions held by different characters (craft on one, process on another).
- GUI: a profession filter alongside the character selector.
