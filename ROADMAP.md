# Roadmap

Open items only; finished work is removed. Release notes are generated from commit history by the release workflow.

## Open items

- Layer observed in-game disenchant results from the addon on top of the Wowhead yield rates.
- Handle vendor faction/location restrictions.
- Confirm the AH tab and recipe capture (`/shuffledetector recipes`) in the Forever client.
- Confirm the in-game shuffle button in the Forever client: crafting via the `spell` attribute (recipe name), the Disenchant `/cast` + `/use <bag> <slot>` macro, and that each press registers.
- Shuffle button follow-ups: a craft count or budget target, and steps beyond craft/disenchant (for example vendor or AH listing) once the calculator can name them.

## Planned: shuffle calculator

Given a chosen shuffle, tell the user how many of each material to buy for a target (budget, craft count, or number of disenchants) and the expected profit. Show the per-step material quantities (including rounding up for yields), total cost at current AH/vendor prices, expected output, and net profit after AH cut, with a range that accounts for disenchant yield variance. Should reuse `calc.py` so it honors the exit filters and known-recipe settings.

## Planned: more professions

Go beyond Tailoring -> Enchanting and consider every profession the scanned characters actually have. The addon already records each character's professions and known recipes, so the companion should read that list and evaluate shuffles for all of them, not just Tailoring.

- Generalize `calc.py` from the hard-coded Tailoring-only known-recipe check to any profession's recipes, with the character filter using whichever professions are present in the scan.
- Extend the Wowhead resolver to fetch recipes, reagents, vendor prices and yields for the other crafting professions (Blacksmithing, Leatherworking, Engineering, Alchemy, Jewelcrafting, Inscription, Cooking, and others available in the client), and for the gathering and processing steps (Mining/smelting, Herbalism/milling, Skinning, prospecting).
- Support other exit steps beyond disenchanting, such as prospecting, milling and salvage, in the same exit comparison.
- Allow chains across professions held by different characters (craft on one, process on another).
- GUI: a profession filter alongside the character selector.
